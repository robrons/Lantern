#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class LanternWebView;

NS_SWIFT_UI_ACTOR
@protocol LanternWebViewDelegate <NSObject>
/// Title, address, loading progress or back/forward availability changed.
- (void)webViewStateDidChange:(LanternWebView *)webView;
- (void)webView:(LanternWebView *)webView didFinishLoading:(nullable NSURL *)url;
- (void)webView:(LanternWebView *)webView didFailWithError:(NSError *)error;
/// A message posted by lantern.js from any frame.
- (void)webView:(LanternWebView *)webView didReceiveMessage:(id)body;
/// A page called alert() or confirm().
- (void)webView:(LanternWebView *)webView
      showAlert:(NSString *)message
        confirm:(BOOL)isConfirm
     completion:(void (^)(BOOL accepted))completion;
@optional
/// The page's process stopped (it crashed or ran out of memory). Without this, the page reloads.
- (void)webViewContentProcessDidTerminate:(LanternWebView *)webView;
/// A script on the page wants to open a window (a sign-in window, or often an ad). Without
/// this, such windows are blocked.
- (BOOL)webView:(LanternWebView *)webView shouldOpenPopupForURL:(NSURL *)url;
/// A window was opened for the page. It stays connected to the page that opened it, which is
/// what sign-in windows need to report back.
- (void)webView:(LanternWebView *)webView didOpenPopup:(LanternWebView *)popup;
/// The page closed its own window (as sign-in windows do when they're finished).
- (void)webViewDidClose:(LanternWebView *)webView;
@end

/// Hosts Safari's web engine, which ships on tvOS but is not part of the public SDK.
/// Everything is resolved at runtime, so this class is the only place that touches it.
NS_SWIFT_UI_ACTOR
@interface LanternWebView : UIView

/// Whether the web engine could be loaded on this device.
+ (BOOL)isEngineAvailable;

/// Test-only: the engine's media-related settings and whether Lantern could change them.
+ (NSString *)engineDiagnostics;

/// `isolatedScript` runs in a private script world in every frame; pages cannot see it.
/// `pageScript` runs alongside the page's own scripts in every frame.
- (instancetype)initWithFrame:(CGRect)frame
               isolatedScript:(NSString *)isolatedScript
                   pageScript:(NSString *)pageScript NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<LanternWebViewDelegate> delegate;
@property (nonatomic, readonly, nullable) NSURL *URL;
@property (nonatomic, readonly, nullable) NSString *title;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic, readonly) double estimatedProgress;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic) CGFloat pageZoom;
/// The page's own scroll view, for smooth native scrolling of the whole page.
@property (nonatomic, readonly, nullable) UIScrollView *scrollView;
/// Identities to give sites; which one a page gets is decided by `prefersMobileSite`.
@property (nonatomic, copy, nullable) NSString *desktopUserAgent;
@property (nonatomic, copy, nullable) NSString *mobileUserAgent;
/// Asked as each page starts loading: whether to request the site's mobile version.
@property (nonatomic, copy, nullable) BOOL (^prefersMobileSite)(NSURL *url);

/// Blocks requests matching WebKit content-blocker rules (JSON). Pages asked for while the
/// rules compile wait for them, so the first page is covered too.
- (void)installContentRules:(NSString *)encodedRules;

/// Shuts down a page that has frozen, so you can leave it. The delegate is told the page's
/// process stopped, and the view is ready to load something else.
- (void)stopFrozenPage;

- (void)loadURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;

/// Runs JavaScript in the top frame's private script world (where lantern.js lives).
- (void)evaluateJavaScript:(NSString *)script
                completion:(nullable void (^)(id _Nullable result, NSError * _Nullable error))completion;

/// The cookies the page has, so a video it plays can be fetched the same way.
- (void)fetchCookies:(void (^)(NSArray<NSHTTPCookie *> *cookies))completion;

- (void)takeSnapshotWithWidth:(CGFloat)width completion:(void (^)(UIImage * _Nullable image))completion;

@end

NS_ASSUME_NONNULL_END
