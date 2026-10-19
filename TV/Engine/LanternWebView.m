#import "LanternWebView.h"

#import <dlfcn.h>
#import <sys/resource.h>

// Declared in libproc.h, which the tvOS SDK doesn't ship.
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const LanternMessageHandlerName = @"lantern";
static void *LanternKVOContext = &LanternKVOContext;

#pragma mark - Runtime helpers

static id LanternGet(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL LanternGetBool(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static void LanternSetBool(id object, NSString *selectorName, BOOL value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object != nil && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

static void LanternSetInteger(id object, NSString *selectorName, NSInteger value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object != nil && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, selector, value);
    }
}

static void LanternSetObject(id object, NSString *selectorName, id value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object != nil && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    }
}

#pragma mark - Engine loading

static NSInteger LanternUnknownPrivacyStance(__unused id self, __unused SEL _cmd) {
    return 0;
}

/// The tvOS build of WebKit's network metrics class lacks a method its media loader calls,
/// which crashes video playback. Answer "unknown" instead.
static void LanternInstallEngineFixes(void) {
    Class metricsClass = NSClassFromString(@"WebCoreNSURLSessionTaskTransactionMetrics");
    if (metricsClass == Nil) {
        return;
    }
    for (NSString *name in @[@"privacyStance", @"_privacyStance"]) {
        SEL selector = NSSelectorFromString(name);
        if (class_getInstanceMethod(metricsClass, selector) == NULL) {
            class_addMethod(metricsClass, selector, (IMP)LanternUnknownPrivacyStance, "q@:");
        }
    }
}

static BOOL LanternLoadEngine(void) {
    static BOOL available = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(@"WKWebView") == Nil) {
            NSArray<NSString *> *paths = @[
                @"/System/Library/Frameworks/WebKit.framework/WebKit",
                @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            ];
            for (NSString *path in paths) {
                if (dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL) != NULL
                    && NSClassFromString(@"WKWebView") != Nil) {
                    break;
                }
            }
        }
        available = NSClassFromString(@"WKWebView") != Nil
            && NSClassFromString(@"WKContentWorld") != Nil;
        if (available) {
            LanternInstallEngineFixes();
        }
    });
    return available;
}

#pragma mark - Bridge

/// Which LanternWebView hosts each engine view. Pop-up windows share their opener's script
/// handler, so messages are routed by the engine view they came from.
static NSMapTable *LanternOwnersByEngine(void) {
    static NSMapTable *owners;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        owners = [NSMapTable weakToWeakObjectsMapTable];
    });
    return owners;
}

@interface LanternWebView ()
- (void)bridgeReceivedMessage:(id)body;
- (void)bridgeDidFinishNavigation;
- (void)bridgeDidFailWithError:(NSError *)error;
- (void)bridgeLoadRequest:(NSURLRequest *)request;
- (void)bridgeContentProcessTerminated;
- (void)bridgeContentProcessTerminatedWithReason:(NSInteger)reason;
- (void)bridgeDidClose;
- (UIView *)engineView;
- (instancetype)initPopupWithFrame:(CGRect)frame configuration:(id)configuration opener:(LanternWebView *)opener NS_DESIGNATED_INITIALIZER;
- (void)bridgeApplySiteModeForURL:(NSURL *)url preferences:(id)preferences;
@end

/// Receives the engine's delegate callbacks. It holds the view weakly because the engine
/// keeps its message handler alive for as long as the engine exists.
@interface LanternWebViewBridge : NSObject
@property (nonatomic, weak) LanternWebView *owner;
@end

@implementation LanternWebViewBridge

+ (void)adoptEngineProtocols {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSString *name in @[@"WKScriptMessageHandler", @"WKNavigationDelegate", @"WKUIDelegate"]) {
            Protocol *protocol = objc_getProtocol(name.UTF8String);
            if (protocol != NULL) {
                class_addProtocol(self, protocol);
            }
        }
    });
}

- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    id body = LanternGet(message, @"body");
    LanternWebView *owner = [LanternOwnersByEngine() objectForKey:LanternGet(message, @"webView")] ?: self.owner;
    if (body != nil) {
        [owner bridgeReceivedMessage:body];
    }
}

- (void)webViewDidClose:(id)webView {
    [self.owner bridgeDidClose];
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.owner bridgeDidFinishNavigation];
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self.owner bridgeDidFailWithError:error];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    [self.owner bridgeDidFailWithError:error];
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    [self.owner bridgeContentProcessTerminated];
}

// The engine prefers this version when present, and says why the page's process stopped.
- (void)_webView:(id)webView webContentProcessDidTerminateWithReason:(NSInteger)reason {
    [self.owner bridgeContentProcessTerminatedWithReason:reason];
}

- (void)webView:(id)webView
    decidePolicyForNavigationAction:(id)navigationAction
                        preferences:(id)preferences
                    decisionHandler:(void (^)(NSInteger policy, id preferences))decisionHandler {
    NSURLRequest *request = LanternGet(navigationAction, @"request");
    NSString *scheme = request.URL.scheme.lowercaseString ?: @"";
    NSArray<NSString *> *webSchemes = @[@"http", @"https", @"about", @"data", @"blob"];
    if (![webSchemes containsObject:scheme]) {
        decisionHandler(0, preferences);
        return;
    }
    // Links that ask for a new window open in place: Lantern has one page at a time.
    id targetFrame = LanternGet(navigationAction, @"targetFrame");
    if (targetFrame == nil) {
        decisionHandler(0, preferences);
        [self.owner bridgeLoadRequest:request];
        return;
    }
    BOOL isMainFrame = LanternGetBool(targetFrame, @"isMainFrame");
    LanternWebView *owner = self.owner;
    id<LanternWebViewDelegate> delegate = owner.delegate;
    if (owner != nil && request.URL != nil) {
        if ([delegate respondsToSelector:@selector(webView:shouldBlockURL:mainFrame:)]
            && [delegate webView:owner shouldBlockURL:request.URL mainFrame:isMainFrame]) {
            decisionHandler(0, preferences);
            return;
        }
        NSURL *replacement = isMainFrame && [delegate respondsToSelector:@selector(webView:replacementForURL:)]
            ? [delegate webView:owner replacementForURL:request.URL]
            : nil;
        if (replacement != nil) {
            decisionHandler(0, preferences);
            NSMutableURLRequest *replacementRequest = [request mutableCopy];
            replacementRequest.URL = replacement;
            [owner bridgeLoadRequest:replacementRequest];
            return;
        }
    }
    if (isMainFrame) {
        [owner bridgeApplySiteModeForURL:request.URL preferences:preferences];
    }
    decisionHandler(1, preferences);
}

- (id)webView:(id)webView
    createWebViewWithConfiguration:(id)configuration
               forNavigationAction:(id)navigationAction
                    windowFeatures:(id)windowFeatures {
    NSURLRequest *request = LanternGet(navigationAction, @"request");
    if (request.URL == nil || request.URL.absoluteString.length == 0) {
        return nil;
    }
    // A link opening in a new tab opens here instead.
    SEL typeSelector = NSSelectorFromString(@"navigationType");
    NSInteger type = [navigationAction respondsToSelector:typeSelector]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(navigationAction, typeSelector)
        : -1;
    LanternWebView *owner = self.owner;
    if (type == 0) {
        [owner bridgeLoadRequest:request];
        return nil;
    }
    // Windows opened by scripts are usually ads, but sign-in windows are opened this way too,
    // and they need a real window that stays connected to the page. The delegate decides.
    id<LanternWebViewDelegate> delegate = owner.delegate;
    if (owner != nil && [delegate respondsToSelector:@selector(webView:shouldOpenPopupForURL:)]
        && [delegate webView:owner shouldOpenPopupForURL:request.URL]) {
        LanternWebView *popup = [[LanternWebView alloc] initPopupWithFrame:owner.bounds configuration:configuration opener:owner];
        if ([delegate respondsToSelector:@selector(webView:didOpenPopup:)]) {
            [delegate webView:owner didOpenPopup:popup];
        }
        return [popup engineView];
    }
    [owner bridgeReceivedMessage:@{@"type": @"popupBlocked", @"url": request.URL.absoluteString}];
    return nil;
}

- (void)webView:(id)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(id)frame
                     completionHandler:(void (^)(void))completionHandler {
    LanternWebView *owner = self.owner;
    if (owner == nil || owner.delegate == nil) {
        completionHandler();
        return;
    }
    [owner.delegate webView:owner showAlert:message confirm:NO completion:^(__unused BOOL accepted) {
        completionHandler();
    }];
}

- (void)webView:(id)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(id)frame
                       completionHandler:(void (^)(BOOL result))completionHandler {
    LanternWebView *owner = self.owner;
    if (owner == nil || owner.delegate == nil) {
        completionHandler(NO);
        return;
    }
    [owner.delegate webView:owner showAlert:message confirm:YES completion:^(BOOL accepted) {
        completionHandler(accepted);
    }];
}

@end

#pragma mark - LanternWebView

@implementation LanternWebView {
    UIView *_engine;
    LanternWebViewBridge *_bridge;
    id _scriptWorld;
    id _userContent;
    BOOL _rulesPending;
    NSURLRequest *_pendingRequest;
}

+ (NSArray<NSString *> *)observedKeys {
    return @[@"title", @"URL", @"loading", @"estimatedProgress", @"canGoBack", @"canGoForward"];
}

+ (BOOL)isEngineAvailable {
    return LanternLoadEngine();
}

+ (void)clearEngineMemoryCaches {
    if (!LanternLoadEngine()) {
        return;
    }
    id store = LanternGet(NSClassFromString(@"WKWebsiteDataStore"), @"defaultDataStore");
    SEL remove = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
    if (store == nil || ![store respondsToSelector:remove]) {
        return;
    }
    void (^done)(void) = ^{};
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, remove, [NSSet setWithObject:@"WKWebsiteDataTypeMemoryCache"], [NSDate distantPast], done);
}

+ (NSString *)engineDiagnostics {
    if (!LanternLoadEngine()) {
        return @"engine unavailable";
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    id preferences = [NSClassFromString(@"WKPreferences") new];
    for (NSString *name in @[@"_setMediaSourceEnabled:", @"_setManagedMediaSourceEnabled:", @"_setEnabled:forFeature:", @"_setBoolValue:forKey:"]) {
        [lines addObject:[NSString stringWithFormat:@"%@ %@", name, [preferences respondsToSelector:NSSelectorFromString(name)] ? @"yes" : @"no"]];
    }
    id features = LanternGet(NSClassFromString(@"WKPreferences"), @"_features");
    for (id feature in features) {
        NSString *key = LanternGet(feature, @"key");
        if ([key.lowercaseString containsString:@"media"] || [key.lowercaseString containsString:@"source"]
            || [key.lowercaseString containsString:@"cache"] || [key.lowercaseString containsString:@"memory"]) {
            BOOL enabled = NO;
            SEL isEnabled = NSSelectorFromString(@"_isEnabledForFeature:");
            if ([preferences respondsToSelector:isEnabled]) {
                enabled = ((BOOL (*)(id, SEL, id))objc_msgSend)(preferences, isEnabled, feature);
            }
            [lines addObject:[NSString stringWithFormat:@"feature %@ = %d", key, enabled]];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (instancetype)initWithFrame:(CGRect)frame isolatedScript:(NSString *)isolatedScript pageScript:(NSString *)pageScript {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    self.backgroundColor = UIColor.blackColor;
    if (!LanternLoadEngine()) {
        return self;
    }

    [LanternWebViewBridge adoptEngineProtocols];
    _bridge = [LanternWebViewBridge new];
    _bridge.owner = self;

    id configuration = [NSClassFromString(@"WKWebViewConfiguration") new];
    LanternSetBool(configuration, @"setAllowsInlineMediaPlayback:", YES);
    // Clicks from the remote are synthesized in JavaScript and never count as a user
    // gesture, so let pages start playback without one.
    LanternSetInteger(configuration, @"setMediaTypesRequiringUserActionForPlayback:", 0);
    LanternSetBool(configuration, @"setAllowsPictureInPictureMediaPlayback:", NO);

    id preferences = LanternGet(configuration, @"preferences");
    LanternSetBool(preferences, @"setJavaScriptCanOpenWindowsAutomatically:", YES);
    // Streaming sites need Media Source Extensions, which tvOS leaves switched off.
    for (NSString *name in @[@"_setMediaSourceEnabled:",
                             @"_setManagedMediaSourceEnabled:",
                             @"_setMediaCapabilityGrantsEnabled:",
                             @"_setVideoQualityIncludesDisplayCompositingEnabled:"]) {
        LanternSetBool(preferences, name, YES);
    }
    // The setters above don't stick on tvOS; switching the features on by name does.
    NSSet<NSString *> *wantedFeatures = [NSSet setWithArray:@[@"MediaSourceEnabled",
                                                             @"ManagedMediaSourceEnabled",
                                                             @"MediaSourceInWorkerEnabled"]];
    SEL setFeature = NSSelectorFromString(@"_setEnabled:forFeature:");
    if ([preferences respondsToSelector:setFeature]) {
        for (id feature in LanternGet(NSClassFromString(@"WKPreferences"), @"_features")) {
            NSString *key = LanternGet(feature, @"key");
            if ([wantedFeatures containsObject:key]) {
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(preferences, setFeature, YES, feature);
            } else if ([key isEqualToString:@"UsesBackForwardCache"]) {
                // Keeping previous pages alive for an instant Back makes each page process keep
                // growing as you browse, and tvOS kills a page process at about 900 MB. Back
                // reloads the page instead.
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(preferences, setFeature, NO, feature);
            } else if ([key hasPrefix:@"WebAuthentication"] || [key hasPrefix:@"DigitalCredentials"]) {
                // Passkey requests reach tvOS's "sign in with iPhone" service, which crashes
                // the app on Apple TV. Sites fall back to passwords when passkeys are off.
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(preferences, setFeature, NO, feature);
            }
        }
    }

    // Pages lay out to the screen's real width so zoom behaves like Safari's (see
    // bridgeApplySiteModeForURL:preferences:).
    id webpagePreferences = LanternGet(configuration, @"defaultWebpagePreferences");
    LanternSetInteger(webpagePreferences, @"setPreferredContentMode:", 1);

    Class worldClass = NSClassFromString(@"WKContentWorld");
    _scriptWorld = ((id (*)(id, SEL, id))objc_msgSend)(worldClass, NSSelectorFromString(@"worldWithName:"), @"lantern");

    id userContent = LanternGet(configuration, @"userContentController");
    _userContent = userContent;
    Class scriptClass = NSClassFromString(@"WKUserScript");
    id isolated = ((id (*)(id, SEL, id, NSInteger, BOOL, id))objc_msgSend)(
        [scriptClass alloc],
        NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:inContentWorld:"),
        isolatedScript, 0, NO, _scriptWorld);
    id page = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(
        [scriptClass alloc],
        NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:"),
        pageScript, 0, NO);
    LanternSetObject(userContent, @"addUserScript:", page);
    LanternSetObject(userContent, @"addUserScript:", isolated);
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        userContent,
        NSSelectorFromString(@"addScriptMessageHandler:contentWorld:name:"),
        _bridge, _scriptWorld, LanternMessageHandlerName);

    [self attachEngineWithConfiguration:configuration];
    return self;
}

/// A window a page opened. It shares the opener's scripts, blocking rules and settings, and
/// uses the configuration the engine supplied so the two pages stay connected.
- (instancetype)initPopupWithFrame:(CGRect)frame configuration:(id)configuration opener:(LanternWebView *)opener {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    self.backgroundColor = UIColor.blackColor;
    _bridge = [LanternWebViewBridge new];
    _bridge.owner = self;
    _scriptWorld = opener->_scriptWorld;
    _userContent = opener->_userContent;
    self.desktopUserAgent = opener.desktopUserAgent;
    self.mobileUserAgent = opener.mobileUserAgent;
    self.prefersMobileSite = opener.prefersMobileSite;
    [self attachEngineWithConfiguration:configuration];
    return self;
}

- (void)attachEngineWithConfiguration:(id)configuration {
    UIView *engine = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(
        [NSClassFromString(@"WKWebView") alloc],
        NSSelectorFromString(@"initWithFrame:configuration:"),
        self.bounds, configuration);
    engine.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // The remote never touches the page directly. Lantern drives it with scripts, which also
    // keeps the page from taking focus away from Lantern's own controls.
    engine.userInteractionEnabled = NO;
    engine.backgroundColor = UIColor.blackColor;
    LanternSetObject(engine, @"setNavigationDelegate:", _bridge);
    LanternSetObject(engine, @"setUIDelegate:", _bridge);
    LanternSetBool(engine, @"setInspectable:", YES);

    UIScrollView *scrollView = LanternGet(engine, @"scrollView");
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;

    // Lay every page out to the screen's width, whatever width the page asks for, the way a
    // desktop browser does. Then page zoom decides how wide the layout is, so zooming in makes
    // text bigger and the page rewraps. Without this, pages that ask for a fixed width (or
    // none) are stretched to fit the screen, which cancels zoom out.
    _layoutZoom = 1;
    _lastStopReason = -1;
    [self applyLayoutZoom];

    [self addSubview:engine];
    _engine = engine;
    [LanternOwnersByEngine() setObject:self forKey:engine];

    for (NSString *key in [LanternWebView observedKeys]) {
        [engine addObserver:self forKeyPath:key options:0 context:LanternKVOContext];
    }
}

- (UIView *)engineView {
    return _engine;
}

- (void)dealloc {
    if (_engine == nil) {
        return;
    }
    for (NSString *key in [LanternWebView observedKeys]) {
        [_engine removeObserver:self forKeyPath:key context:LanternKVOContext];
    }
    LanternSetObject(_engine, @"setNavigationDelegate:", nil);
    LanternSetObject(_engine, @"setUIDelegate:", nil);
    id configuration = LanternGet(_engine, @"configuration");
    id userContent = LanternGet(configuration, @"userContentController");
    if ([userContent respondsToSelector:NSSelectorFromString(@"removeAllScriptMessageHandlers")]) {
        ((void (*)(id, SEL))objc_msgSend)(userContent, NSSelectorFromString(@"removeAllScriptMessageHandlers"));
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context != LanternKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self.delegate webViewStateDidChange:self];
}

#pragma mark State

- (NSURL *)URL {
    return LanternGet(_engine, @"URL");
}

- (NSString *)title {
    return LanternGet(_engine, @"title");
}

- (BOOL)isLoading {
    return LanternGetBool(_engine, @"isLoading");
}

- (double)estimatedProgress {
    SEL selector = NSSelectorFromString(@"estimatedProgress");
    if (![_engine respondsToSelector:selector]) {
        return 0;
    }
    return ((double (*)(id, SEL))objc_msgSend)(_engine, selector);
}

- (BOOL)canGoBack {
    return LanternGetBool(_engine, @"canGoBack");
}

- (BOOL)canGoForward {
    return LanternGetBool(_engine, @"canGoForward");
}

- (void)setLayoutZoom:(CGFloat)layoutZoom {
    _layoutZoom = MAX(0.25, layoutZoom);
    [self applyLayoutZoom];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self applyLayoutZoom];
}

/// Tells the engine to lay pages out as if the screen were narrower by the zoom factor, at a
/// fixed scale that fills the view, whatever the page itself asks for.
- (void)applyLayoutZoom {
    SEL overrideViewport = NSSelectorFromString(@"_overrideViewportWithArguments:");
    CGFloat viewWidth = self.bounds.size.width;
    if (_engine == nil || viewWidth <= 0 || ![_engine respondsToSelector:overrideViewport]) {
        return;
    }
    NSString *width = [NSString stringWithFormat:@"%ld", (long)lround(viewWidth / _layoutZoom)];
    NSString *scale = [NSString stringWithFormat:@"%.4f", viewWidth / lround(viewWidth / _layoutZoom)];
    NSDictionary *arguments = @{
        @"width": width,
        @"initial-scale": scale,
        @"minimum-scale": scale,
        @"maximum-scale": scale,
        @"user-scalable": @"no",
    };
    ((void (*)(id, SEL, id))objc_msgSend)(_engine, overrideViewport, arguments);
}

- (CGFloat)pageZoom {
    SEL selector = NSSelectorFromString(@"pageZoom");
    if (![_engine respondsToSelector:selector]) {
        return 1;
    }
    return ((CGFloat (*)(id, SEL))objc_msgSend)(_engine, selector);
}

- (void)setPageZoom:(CGFloat)pageZoom {
    SEL selector = NSSelectorFromString(@"setPageZoom:");
    if ([_engine respondsToSelector:selector]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(_engine, selector, pageZoom);
    }
}


#pragma mark Navigation

- (void)installContentRules:(NSString *)encodedRules {
    id store = LanternGet(NSClassFromString(@"WKContentRuleListStore"), @"defaultStore");
    SEL compile = NSSelectorFromString(@"compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:");
    if (store == nil || ![store respondsToSelector:compile] || _userContent == nil) {
        return;
    }
    _rulesPending = YES;
    __weak LanternWebView *weakSelf = self;
    void (^handler)(id, NSError *) = ^(id list, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishInstallingRules:list error:error];
        });
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, compile, @"LanternBlockedDomains", encodedRules, handler);
    // Don't hold pages back for long if compiling stalls.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf finishInstallingRules:nil error:nil];
    });
}

- (void)finishInstallingRules:(id)list error:(NSError *)error {
    if (list != nil) {
        LanternSetObject(_userContent, @"addContentRuleList:", list);
    }
    if (error != nil) {
        NSLog(@"Lantern: blocking rules failed to compile: %@", error);
    }
    if (!_rulesPending) {
        return;
    }
    _rulesPending = NO;
    if (_pendingRequest != nil) {
        NSURLRequest *request = _pendingRequest;
        _pendingRequest = nil;
        [self bridgeLoadRequest:request];
    }
}

- (void)stopFrozenPage {
    for (NSString *name in @[@"_killWebContentProcess", @"_killWebContentProcessAndResetState"]) {
        SEL selector = NSSelectorFromString(name);
        if ([_engine respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(_engine, selector);
            return;
        }
    }
}

- (void)loadURL:(NSURL *)url {
    [self bridgeLoadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)goBack {
    (void)LanternGet(_engine, @"goBack");
}

- (void)goForward {
    (void)LanternGet(_engine, @"goForward");
}

- (void)reload {
    (void)LanternGet(_engine, @"reload");
}

- (void)stopLoading {
    (void)LanternGet(_engine, @"stopLoading");
}

- (void)evaluateJavaScript:(NSString *)script completion:(void (^)(id, NSError *))completion {
    SEL selector = NSSelectorFromString(@"evaluateJavaScript:inFrame:inContentWorld:completionHandler:");
    if (![_engine respondsToSelector:selector]) {
        if (completion != nil) {
            completion(nil, nil);
        }
        return;
    }
    void (^handler)(id, NSError *) = ^(id result, NSError *error) {
        if (completion != nil) {
            completion(result, error);
        }
    };
    ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(_engine, selector, script, nil, _scriptWorld, handler);
}

- (void)fetchCookies:(void (^)(NSArray<NSHTTPCookie *> *))completion {
    id configuration = LanternGet(_engine, @"configuration");
    id store = LanternGet(LanternGet(configuration, @"websiteDataStore"), @"httpCookieStore");
    SEL selector = NSSelectorFromString(@"getAllCookies:");
    if (store == nil || ![store respondsToSelector:selector]) {
        completion(@[]);
        return;
    }
    void (^handler)(NSArray *) = ^(NSArray *cookies) {
        completion(cookies ?: @[]);
    };
    ((void (*)(id, SEL, id))objc_msgSend)(store, selector, handler);
}

- (void)takeSnapshotWithWidth:(CGFloat)width completion:(void (^)(UIImage *))completion {
    SEL selector = NSSelectorFromString(@"takeSnapshotWithConfiguration:completionHandler:");
    if (![_engine respondsToSelector:selector]) {
        completion(nil);
        return;
    }
    id configuration = [NSClassFromString(@"WKSnapshotConfiguration") new];
    LanternSetObject(configuration, @"setSnapshotWidth:", @(width));
    void (^handler)(UIImage *, NSError *) = ^(UIImage *image, __unused NSError *error) {
        completion(image);
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(_engine, selector, configuration, handler);
}

#pragma mark Bridge callbacks

- (void)bridgeReceivedMessage:(id)body {
    [self.delegate webView:self didReceiveMessage:body];
}

- (void)bridgeDidFinishNavigation {
    [self.delegate webView:self didFinishLoading:self.URL];
}

- (void)bridgeDidFailWithError:(NSError *)error {
    // Cancelled loads and loads replaced by a new navigation are not failures.
    BOOL cancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
    BOOL interrupted = [error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102;
    // A page trying to send you to a blocked ad network stays where it was.
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 104) {
        [self bridgeReceivedMessage:@{@"type": @"adBlocked"}];
        return;
    }
    if (!cancelled && !interrupted) {
        [self.delegate webView:self didFailWithError:error];
    }
}

- (void)bridgeLoadRequest:(NSURLRequest *)request {
    if (_rulesPending) {
        _pendingRequest = request;
        return;
    }
    LanternSetObject(_engine, @"loadRequest:", request);
}

- (void)bridgeDidClose {
    if ([self.delegate respondsToSelector:@selector(webViewDidClose:)]) {
        [self.delegate webViewDidClose:self];
    }
}

- (void)bridgeContentProcessTerminatedWithReason:(NSInteger)reason {
    _lastStopReason = reason;
    [self bridgeContentProcessTerminated];
    _lastStopReason = -1;
}

- (uint64_t)pageMemoryFootprint {
    SEL selector = NSSelectorFromString(@"_webProcessIdentifier");
    if (![_engine respondsToSelector:selector]) {
        return 0;
    }
    pid_t pid = ((pid_t (*)(id, SEL))objc_msgSend)(_engine, selector);
    struct rusage_info_v4 info;
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) {
        return 0;
    }
    return info.ri_phys_footprint;
}

- (void)bridgeContentProcessTerminated {
    if ([self.delegate respondsToSelector:@selector(webViewContentProcessDidTerminate:)]) {
        [self.delegate webViewContentProcessDidTerminate:self];
    } else {
        [self reload];
    }
}

- (UIScrollView *)scrollView {
    return LanternGet(_engine, @"scrollView");
}

- (void)bridgeApplySiteModeForURL:(NSURL *)url preferences:(id)preferences {
    BOOL mobile = url != nil && self.prefersMobileSite != nil && self.prefersMobileSite(url);
    NSString *agent = mobile ? self.mobileUserAgent : self.desktopUserAgent;
    // Lay every page out to the screen's real width (1 is WKContentModeMobile). The engine's
    // desktop mode refits pages to the screen with its own scaling, which cancels out zoom;
    // sites still get the desktop version from the desktop identity below.
    LanternSetInteger(preferences, @"setPreferredContentMode:", 1);
    LanternSetObject(preferences, @"_setCustomUserAgent:", agent);
    LanternSetObject(_engine, @"setCustomUserAgent:", agent);
}

@end
