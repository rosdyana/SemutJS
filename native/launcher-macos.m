// semut launcher (macOS): owns the window and the WKWebView, and is the
// rendezvous point for the Tov backend.
//
// Tov has no FFI, sockets or stdin, but its fetch() speaks HTTP over a Unix
// socket ({ unix: path }). So the launcher is a tiny HTTP/1.1 server on a
// socket inside a private 0700 temp dir, and the backend is its client:
//
//   backend -> GET  /next   long poll; answers a JSON array of calls
//                           [{ "id": 1, "method": "hello", "params": "<json>" }]
//                           (or [] after ~25 s of nothing)
//   backend -> POST /out    JSON array of messages, applied in order:
//                           { "t": "ret",   "id", "ok", "value": "<json>" | "error": "msg" }
//                           { "t": "emit",  "event", "data": "<json>" }
//                           { "t": "title", "value" } · { "t": "size", "width", "height" }
//                           { "t": "quit" }
//
// Values travel as JSON *text* end to end (the page JSON.parses them), so no
// number or string is ever re-encoded on the way through. Nothing listens on
// a port. id 0 with method "__ready" tells the backend the page has loaded.
//
// Dev plumbing (only honored outside a built .app): SEMUT_FRONTEND (dir with
// index.html), SEMUT_BACKEND (binary), SEMUT_TITLE, SEMUT_SIZE ("960x640"),
// SEMUT_NAME, SEMUT_VERSION, SEMUT_APP_ID, SEMUT_DEV=1. The backend gets
// SEMUT_SOCKET, SEMUT_APP_ID and (in dev) SEMUT_DEV, and no other SEMUT_*. In dev, SIGUSR1 restarts the backend
// and SIGUSR2 reloads the page (the CLI sends them after a rebuild/edit).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include "client.h"  // semut_client_js[] / semut_client_js_len, from runtime/semut.js

extern char **environ;

// ── shared state ────────────────────────────────────────────────────────────
// The inbox is touched by socket threads, so it is guarded by qlock. Every
// other piece of state belongs to the main thread.

static pthread_mutex_t qlock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t qcond = PTHREAD_COND_INITIALIZER;
static NSMutableArray<NSDictionary *> *inbox;  // calls not yet handed to the backend

typedef void (^Reply)(id result, NSString *error);
static NSMutableDictionary<NSNumber *, Reply> *pending;  // calls awaiting a "ret"
static long long nextCallId = 1;

static NSString *sockPath, *workDir;
static NSString *frontendDir, *backendPath;
static NSString *appName, *appVersion, *appTitle, *appId;
static NSSize appSize;
static BOOL devMode;
static pid_t backendPid = 0;
static int backendGen = 0;  // bumped per spawn so a stale exit can't clobber a new child

@class AppDelegate;
static AppDelegate *delegate;

static void enqueue(NSDictionary *call) {
  pthread_mutex_lock(&qlock);
  [inbox addObject:call];
  pthread_cond_broadcast(&qcond);
  pthread_mutex_unlock(&qlock);
}

static NSString *jsonText(id obj) {
  if (obj == nil) obj = [NSNull null];
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                              options:NSJSONWritingFragmentsAllowed
                                                error:nil];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"null";
}

// ── app delegate: window, webview, native built-ins ─────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate>
@property(strong) NSWindow *window;
@property(strong) WKWebView *web;
@property BOOL pageReady;
@property(strong) NSMutableArray<NSArray *> *earlyEmits;
- (void)applyOut:(NSArray *)msgs;
- (void)backendExited:(int)status gen:(int)gen;
@end

static void spawnBackend(void);

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
  [self buildMenu];
  self.earlyEmits = [NSMutableArray array];

  WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
  WKUserContentController *ucc = [WKUserContentController new];
  NSString *client = [[NSString alloc] initWithBytes:semut_client_js
                                              length:semut_client_js_len
                                            encoding:NSUTF8StringEncoding];
  if (devMode)
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:@"window.__SEMUT_DEV__ = true;"
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:YES]];
  [ucc addUserScript:[[WKUserScript alloc] initWithSource:client
                                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                         forMainFrameOnly:YES]];
  [ucc addScriptMessageHandlerWithReply:self contentWorld:WKContentWorld.pageWorld name:@"semut"];
  cfg.userContentController = ucc;
  [cfg.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];

  NSRect frame = NSMakeRect(0, 0, appSize.width, appSize.height);
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.title = appTitle;
  self.window.delegate = self;
  self.window.releasedWhenClosed = NO;
  [self.window center];
  [self.window setFrameAutosaveName:@"semut-main"];

  self.web = [[WKWebView alloc] initWithFrame:frame configuration:cfg];
  self.web.navigationDelegate = self;
  self.web.UIDelegate = self;
  if (@available(macOS 13.3, *)) self.web.inspectable = devMode;
  self.window.contentView = self.web;

  [self loadPage];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)loadPage {
  NSURL *dir = [NSURL fileURLWithPath:frontendDir isDirectory:YES];
  [self.web loadFileURL:[dir URLByAppendingPathComponent:@"index.html"] allowingReadAccessToURL:dir];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (void)applicationWillTerminate:(NSNotification *)n {
  if (backendPid > 0) kill(backendPid, SIGTERM);
  if (sockPath) unlink(sockPath.fileSystemRepresentation);
  if (workDir) rmdir(workDir.fileSystemRepresentation);
}

- (void)buildMenu {
  NSMenu *bar = [NSMenu new];
  NSMenuItem *appItem = [NSMenuItem new];
  NSMenu *appMenu = [NSMenu new];
  [appMenu addItemWithTitle:[@"About " stringByAppendingString:appName]
                     action:@selector(orderFrontStandardAboutPanel:)
              keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
  [appMenu addItemWithTitle:[@"Hide " stringByAppendingString:appName] action:@selector(hide:) keyEquivalent:@"h"];
  [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:appName] action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = appMenu;
  [bar addItem:appItem];

  // Without an Edit menu, Cmd+C/V/X/A/Z never reach the webview.
  NSMenuItem *editItem = [NSMenuItem new];
  NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
  [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  editItem.submenu = edit;
  [bar addItem:editItem];

  NSMenuItem *winItem = [NSMenuItem new];
  NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
  [win addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  [win addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
  if (devMode) {
    [win addItem:[NSMenuItem separatorItem]];
    NSMenuItem *reload = [win addItemWithTitle:@"Reload" action:@selector(reloadPage:) keyEquivalent:@"r"];
    reload.target = self;
  }
  winItem.submenu = win;
  [bar addItem:winItem];
  NSApp.windowsMenu = win;
  NSApp.mainMenu = bar;
}

- (void)reloadPage:(id)sender { [self loadPage]; }

// ── navigation: page readiness, external links ─────────────────────────────

- (void)webView:(WKWebView *)w didStartProvisionalNavigation:(WKNavigation *)nav {
  self.pageReady = NO;
}

- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)nav {
  self.pageReady = YES;
  for (NSArray *e in self.earlyEmits) [self emit:e[0] data:e[1]];
  [self.earlyEmits removeAllObjects];
  enqueue(@{@"id" : @0, @"method" : @"__ready", @"params" : @"{}"});
}

- (void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decide {
  NSURL *url = action.request.URL;
  // The app is its local files. A link that leaves them opens in the browser.
  if (action.targetFrame.isMainFrame && ![url.scheme isEqualToString:@"file"] &&
      ![url.scheme isEqualToString:@"about"]) {
    if ([@[ @"http", @"https", @"mailto" ] containsObject:url.scheme.lowercaseString])
      [[NSWorkspace sharedWorkspace] openURL:url];
    decide(WKNavigationActionPolicyCancel);
    return;
  }
  decide(WKNavigationActionPolicyAllow);
}

// target=_blank / window.open: open externally rather than silently dropping.
- (WKWebView *)webView:(WKWebView *)w createWebViewWithConfiguration:(WKWebViewConfiguration *)c
    forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)f {
  NSURL *url = action.request.URL;
  if ([@[ @"http", @"https", @"mailto" ] containsObject:url.scheme.lowercaseString])
    [[NSWorkspace sharedWorkspace] openURL:url];
  return nil;
}

// window.alert/confirm from page code: answer with real NSAlerts.
- (void)webView:(WKWebView *)w runJavaScriptAlertPanelWithMessage:(NSString *)msg
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))done {
  NSAlert *a = [NSAlert new];
  a.messageText = msg;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) { done(); }];
}

- (void)webView:(WKWebView *)w runJavaScriptConfirmPanelWithMessage:(NSString *)msg
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))done {
  NSAlert *a = [NSAlert new];
  a.messageText = msg;
  [a addButtonWithTitle:@"OK"];
  [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window
            completionHandler:^(NSModalResponse r) { done(r == NSAlertFirstButtonReturn); }];
}

// ── page -> native / backend ────────────────────────────────────────────────

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)msg
                 replyHandler:(void (^)(id, NSString *))reply {
  // Only our own top-level page may call in (no iframes from elsewhere).
  if (!msg.frameInfo.isMainFrame || ![msg.frameInfo.request.URL.scheme isEqualToString:@"file"]) {
    reply(nil, @"semut: calls are only accepted from the app's own page");
    return;
  }
  NSDictionary *body = [msg.body isKindOfClass:NSDictionary.class] ? msg.body : nil;
  NSString *method = [body[@"method"] isKindOfClass:NSString.class] ? body[@"method"] : nil;
  NSString *params = [body[@"params"] isKindOfClass:NSString.class] ? body[@"params"] : @"{}";
  if (!method.length) {
    reply(nil, @"semut: call needs a method name");
    return;
  }

  if ([self builtin:method params:params reply:reply]) return;

  if (!backendPath) {
    reply(nil, @"semut: this app has no backend");
    return;
  }
  NSNumber *cid = @(nextCallId++);
  pending[cid] = [reply copy];
  enqueue(@{@"id" : cid, @"method" : method, @"params" : params});
}

static NSString *str(NSDictionary *p, NSString *k) {
  id v = p[k];
  return [v isKindOfClass:NSString.class] ? v : nil;
}

- (BOOL)builtin:(NSString *)method params:(NSString *)paramsJson reply:(void (^)(id, NSString *))reply {
  NSArray *prefixes = @[ @"dialog.", @"win.", @"clipboard.", @"shell.", @"app." ];
  BOOL ours = NO;
  for (NSString *p in prefixes) ours = ours || [method hasPrefix:p];
  if (!ours) return NO;

  id parsed = [NSJSONSerialization JSONObjectWithData:[paramsJson dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0
                                                error:nil];
  NSDictionary *p = [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
  void (^ok)(id) = ^(id v) { reply(jsonText(v), nil); };

  if ([method isEqualToString:@"dialog.openFile"] || [method isEqualToString:@"dialog.pickFolder"]) {
    BOOL folder = [method isEqualToString:@"dialog.pickFolder"];
    BOOL multiple = [p[@"multiple"] boolValue];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = !folder;
    panel.canChooseDirectories = folder;
    panel.allowsMultipleSelection = multiple;
    panel.canCreateDirectories = folder;
    if (str(p, @"title")) panel.message = str(p, @"title");
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse r) {
                    if (r != NSModalResponseOK) return ok(nil);
                    NSMutableArray *paths = [NSMutableArray array];
                    for (NSURL *u in panel.URLs) [paths addObject:u.path];
                    ok(multiple ? paths : paths.firstObject);
                  }];
  } else if ([method isEqualToString:@"dialog.saveFile"]) {
    NSSavePanel *panel = [NSSavePanel savePanel];
    if (str(p, @"name")) panel.nameFieldStringValue = str(p, @"name");
    if (str(p, @"title")) panel.message = str(p, @"title");
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse r) { ok(r == NSModalResponseOK ? panel.URL.path : nil); }];
  } else if ([method isEqualToString:@"dialog.alert"] || [method isEqualToString:@"dialog.confirm"]) {
    BOOL confirm = [method isEqualToString:@"dialog.confirm"];
    NSAlert *a = [NSAlert new];
    a.messageText = str(p, @"message") ?: @"";
    a.informativeText = str(p, @"detail") ?: @"";
    [a addButtonWithTitle:@"OK"];
    if (confirm) [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) { ok(@(r == NSAlertFirstButtonReturn)); }];
  } else if ([method isEqualToString:@"win.setTitle"]) {
    self.window.title = str(p, @"title") ?: @"";
    ok(nil);
  } else if ([method isEqualToString:@"win.setSize"]) {
    [self resizeTo:NSMakeSize([p[@"width"] doubleValue], [p[@"height"] doubleValue])];
    ok(nil);
  } else if ([method isEqualToString:@"clipboard.readText"]) {
    ok([NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"");
  } else if ([method isEqualToString:@"clipboard.writeText"]) {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:str(p, @"text") ?: @"" forType:NSPasteboardTypeString];
    ok(nil);
  } else if ([method isEqualToString:@"shell.openExternal"]) {
    NSURL *u = [NSURL URLWithString:str(p, @"url") ?: @""];
    if (![@[ @"http", @"https", @"mailto" ] containsObject:u.scheme.lowercaseString]) {
      reply(nil, @"shell.openExternal: only http, https and mailto URLs");
    } else {
      ok(@([[NSWorkspace sharedWorkspace] openURL:u]));
    }
  } else if ([method isEqualToString:@"app.info"]) {
    ok(@{
      @"name" : appName,
      @"version" : appVersion,
      @"id" : appId,
      @"dev" : devMode ? @YES : @NO,
      @"backend" : backendPath ? @YES : @NO,
      @"pid" : @(getpid()),
    });
  } else if ([method isEqualToString:@"app.log"]) {
    // Dev: the page's console, mirrored to the terminal running semut dev.
    if (devMode) fprintf(stderr, "[page %s] %s\n", (str(p, @"level") ?: @"log").UTF8String, (str(p, @"text") ?: @"").UTF8String);
    ok(nil);
  } else if ([method isEqualToString:@"app.quit"]) {
    ok(nil);
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
  } else {
    reply(nil, [@"semut: unknown built-in " stringByAppendingString:method]);
  }
  return YES;
}

- (void)resizeTo:(NSSize)size {
  if (size.width < 100 || size.height < 100) return;
  NSRect f = self.window.frame;
  NSRect content = [self.window contentRectForFrameRect:f];
  CGFloat top = NSMaxY(f);
  content.size = size;
  NSRect nf = [self.window frameRectForContentRect:content];
  nf.origin.y = top - nf.size.height;  // grow downward, keep the title bar put
  [self.window setFrame:nf display:YES animate:NO];
}

// ── backend -> page / window ────────────────────────────────────────────────

- (void)emit:(NSString *)event data:(NSString *)dataJson {
  if (!self.pageReady) {
    [self.earlyEmits addObject:@[ event, dataJson ]];
    return;
  }
  // Arguments are passed as values, never spliced into source.
  [self.web callAsyncJavaScript:@"if (window.semut) window.semut._emit(e, JSON.parse(d))"
                      arguments:@{@"e" : event, @"d" : dataJson}
                        inFrame:nil
                 inContentWorld:WKContentWorld.pageWorld
              completionHandler:nil];
}

- (void)applyOut:(NSArray *)msgs {
  for (NSDictionary *m in msgs) {
    if (![m isKindOfClass:NSDictionary.class]) continue;
    NSString *t = str(m, @"t");
    if ([t isEqualToString:@"ret"]) {
      NSNumber *cid = [m[@"id"] isKindOfClass:NSNumber.class] ? m[@"id"] : nil;
      Reply r = cid ? pending[cid] : nil;
      if (!r) continue;
      [pending removeObjectForKey:cid];
      if ([m[@"ok"] boolValue]) r(str(m, @"value") ?: @"null", nil);
      else r(nil, str(m, @"error") ?: @"backend error");
    } else if ([t isEqualToString:@"emit"]) {
      NSString *ev = str(m, @"event"), *data = str(m, @"data");
      if (ev && data) [self emit:ev data:data];
    } else if ([t isEqualToString:@"title"]) {
      self.window.title = str(m, @"value") ?: @"";
    } else if ([t isEqualToString:@"size"]) {
      [self resizeTo:NSMakeSize([m[@"width"] doubleValue], [m[@"height"] doubleValue])];
    } else if ([t isEqualToString:@"quit"]) {
      [NSApp terminate:nil];
    }
  }
}

- (void)backendExited:(int)status gen:(int)gen {
  if (gen != backendGen) return;  // an old child, already replaced
  backendPid = 0;
  // Calls the backend had taken are gone with it; calls still in the inbox
  // stay queued for the next backend (dev restarts).
  NSMutableSet *queued = [NSMutableSet set];
  pthread_mutex_lock(&qlock);
  for (NSDictionary *c in inbox) [queued addObject:c[@"id"]];
  pthread_mutex_unlock(&qlock);
  for (NSNumber *cid in pending.allKeys) {
    if ([queued containsObject:cid]) continue;
    pending[cid](nil, @"semut: the backend exited before answering");
    [pending removeObjectForKey:cid];
  }
  if (WIFEXITED(status)) fprintf(stderr, "semut: backend exited (%d)\n", WEXITSTATUS(status));
  else if (WIFSIGNALED(status) && WTERMSIG(status) != SIGTERM) fprintf(stderr, "semut: backend killed by signal %d\n", WTERMSIG(status));
}

@end

// ── backend process ─────────────────────────────────────────────────────────

static void spawnBackend(void) {
  if (!backendPath) return;
  NSMutableArray *env = [NSMutableArray array];
  for (char **e = environ; *e; e++) {
    if (strncmp(*e, "SEMUT_", 6) != 0) [env addObject:@(*e)];
  }
  [env addObject:[@"SEMUT_SOCKET=" stringByAppendingString:sockPath]];
  [env addObject:[@"SEMUT_APP_ID=" stringByAppendingString:appId]];
  if (devMode) [env addObject:@"SEMUT_DEV=1"];
  size_t n = env.count;
  char **envp = calloc(n + 1, sizeof(char *));
  for (size_t i = 0; i < n; i++) envp[i] = strdup([env[i] UTF8String]);

  const char *path = backendPath.fileSystemRepresentation;
  char *argv[] = {(char *)path, NULL};
  pid_t pid;
  int rc = posix_spawn(&pid, path, NULL, NULL, argv, envp);
  for (size_t i = 0; i < n; i++) free(envp[i]);
  free(envp);
  if (rc != 0) {
    fprintf(stderr, "semut: cannot start backend %s: %s\n", path, strerror(rc));
    return;
  }
  backendPid = pid;
  int gen = ++backendGen;
  dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT,
                                                 dispatch_get_main_queue());
  dispatch_source_set_event_handler(src, ^{
    int status = 0;
    waitpid(pid, &status, 0);
    [delegate backendExited:status gen:gen];
    dispatch_source_cancel(src);
  });
  dispatch_resume(src);
}

static void restartBackend(void) {
  if (backendPid > 0) {
    pid_t old = backendPid;
    backendGen++;  // the old child's exit is now stale
    backendPid = 0;
    kill(old, SIGTERM);
    int status;
    waitpid(old, &status, 0);
    [delegate backendExited:0 gen:backendGen];  // reject what the old one held
  }
  spawnBackend();
}

// ── the socket: a minimal HTTP/1.1 server ───────────────────────────────────

static BOOL writeAll(int fd, const void *buf, size_t len) {
  const char *p = buf;
  while (len > 0) {
    ssize_t w = write(fd, p, len);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) return NO;
    p += w;
    len -= (size_t)w;
  }
  return YES;
}

static BOOL respond(int fd, int status, NSData *body) {
  const char *reason = status == 200 ? "OK" : status == 204 ? "No Content" : status == 400 ? "Bad Request" : "Not Found";
  NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                                               "Content-Length: %lu\r\n\r\n",
                                              status, reason, (unsigned long)body.length];
  NSData *h = [head dataUsingEncoding:NSUTF8StringEncoding];
  return writeAll(fd, h.bytes, h.length) && writeAll(fd, body.bytes, body.length);
}

// True once the peer has hung up (a killed backend mid long-poll).
static BOOL peerGone(int fd) {
  struct pollfd pfd = {fd, POLLIN, 0};
  if (poll(&pfd, 1, 0) <= 0) return NO;
  if (pfd.revents & (POLLHUP | POLLERR)) return YES;
  char c;
  return recv(fd, &c, 1, MSG_PEEK | MSG_DONTWAIT) == 0;
}

static NSData *takeCalls(int fd) {
  NSArray *batch = nil;
  pthread_mutex_lock(&qlock);
  for (int slice = 0; slice < 25 && inbox.count == 0; slice++) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 1;
    pthread_cond_timedwait(&qcond, &qlock, &ts);
    if (inbox.count == 0 && peerGone(fd)) {
      pthread_mutex_unlock(&qlock);
      return nil;
    }
  }
  if (!peerGone(fd)) {
    batch = [inbox copy];
    [inbox removeAllObjects];
  }
  pthread_mutex_unlock(&qlock);
  if (!batch) return nil;
  return [NSJSONSerialization dataWithJSONObject:batch options:0 error:nil];
}

static void *connThread(void *arg) {
  int fd = (int)(intptr_t)arg;
  NSMutableData *buf = [NSMutableData data];
  char chunk[16384];
  for (;;) {
    @autoreleasepool {
      // Read the head.
      NSRange end;
      while ((end = [buf rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                             options:0
                               range:NSMakeRange(0, buf.length)]).location == NSNotFound) {
        if (buf.length > 65536) goto done;
        ssize_t r = read(fd, chunk, sizeof chunk);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) goto done;
        [buf appendBytes:chunk length:(NSUInteger)r];
      }
      NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)]
                                             encoding:NSUTF8StringEncoding];
      [buf replaceBytesInRange:NSMakeRange(0, end.location + 4) withBytes:NULL length:0];
      NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
      NSArray *req = [lines.firstObject componentsSeparatedByString:@" "];
      if (req.count < 2) goto done;
      NSString *verb = req[0], *path = req[1];
      NSUInteger clen = 0;
      BOOL wantClose = NO;
      for (NSString *l in lines) {
        NSRange c = [l rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        NSString *k = [[l substringToIndex:c.location] lowercaseString];
        NSString *v = [[l substringFromIndex:c.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([k isEqualToString:@"content-length"]) clen = (NSUInteger)v.longLongValue;
        if ([k isEqualToString:@"connection"] && [v.lowercaseString isEqualToString:@"close"]) wantClose = YES;
        if ([k isEqualToString:@"transfer-encoding"]) goto done;  // our client always sends a length
      }
      if (clen > 64 * 1024 * 1024) goto done;
      while (buf.length < clen) {
        ssize_t r = read(fd, chunk, sizeof chunk);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) goto done;
        [buf appendBytes:chunk length:(NSUInteger)r];
      }
      NSData *body = [buf subdataWithRange:NSMakeRange(0, clen)];
      [buf replaceBytesInRange:NSMakeRange(0, clen) withBytes:NULL length:0];

      BOOL ok;
      if ([verb isEqualToString:@"GET"] && [path isEqualToString:@"/next"]) {
        NSData *calls = takeCalls(fd);
        if (!calls) goto done;
        ok = respond(fd, 200, calls);
      } else if ([verb isEqualToString:@"POST"] && [path isEqualToString:@"/out"]) {
        id msgs = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if ([msgs isKindOfClass:NSArray.class]) {
          dispatch_async(dispatch_get_main_queue(), ^{ [delegate applyOut:msgs]; });
          ok = respond(fd, 204, [NSData data]);
        } else {
          ok = respond(fd, 400, [@"\"/out wants a JSON array\"" dataUsingEncoding:NSUTF8StringEncoding]);
        }
      } else {
        ok = respond(fd, 404, [@"\"not found\"" dataUsingEncoding:NSUTF8StringEncoding]);
      }
      if (!ok || wantClose) goto done;
    }
  }
done:
  close(fd);
  return NULL;
}

static BOOL startServer(void) {
  NSString *tmpl = [NSTemporaryDirectory() stringByAppendingPathComponent:@"semut-XXXXXX"];
  char *dir = strdup(tmpl.fileSystemRepresentation);
  if (!mkdtemp(dir)) {  // mkdtemp makes it 0700
    perror("semut: mkdtemp");
    return NO;
  }
  workDir = @(dir);
  free(dir);
  sockPath = [workDir stringByAppendingPathComponent:@"b.sock"];

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  if (strlen(sockPath.fileSystemRepresentation) >= sizeof addr.sun_path) {
    fprintf(stderr, "semut: socket path too long: %s\n", sockPath.UTF8String);
    return NO;
  }
  strcpy(addr.sun_path, sockPath.fileSystemRepresentation);
  if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 16) != 0) {
    perror("semut: socket");
    return NO;
  }
  [NSThread detachNewThreadWithBlock:^{
    for (;;) {
      int c = accept(fd, NULL, NULL);
      if (c < 0) {
        if (errno == EINTR) continue;
        break;
      }
      int one = 1;
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
      pthread_t t;
      pthread_create(&t, NULL, connThread, (void *)(intptr_t)c);
      pthread_detach(t);
    }
  }];
  return YES;
}

// ── configuration and main ──────────────────────────────────────────────────

static void configure(void) {
  NSBundle *bundle = NSBundle.mainBundle;
  NSDictionary *info = bundle.infoDictionary;
  if (info[@"SemutTitle"]) {
    // A built .app runs as built: no env knob may swap its page or backend.
    NSString *res = bundle.resourcePath;
    frontendDir = [res stringByAppendingPathComponent:@"app"];
    NSString *be = [res stringByAppendingPathComponent:@"backend"];
    backendPath = [NSFileManager.defaultManager isExecutableFileAtPath:be] ? be : nil;
    appTitle = info[@"SemutTitle"];
    appName = info[@"CFBundleName"] ?: appTitle;
    appVersion = info[@"CFBundleShortVersionString"] ?: @"0.0.0";
    appId = info[@"CFBundleIdentifier"] ?: appName;
    NSString *size = info[@"SemutSize"] ?: @"960x640";
    NSArray *wh = [size componentsSeparatedByString:@"x"];
    appSize = NSMakeSize([wh.firstObject doubleValue], [wh.lastObject doubleValue]);
    devMode = NO;
    return;
  }
  NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
  frontendDir = env[@"SEMUT_FRONTEND"] ?: NSFileManager.defaultManager.currentDirectoryPath;
  backendPath = env[@"SEMUT_BACKEND"].length ? env[@"SEMUT_BACKEND"] : nil;
  appName = env[@"SEMUT_NAME"] ?: @"semut";
  appTitle = env[@"SEMUT_TITLE"] ?: appName;
  appVersion = env[@"SEMUT_VERSION"] ?: @"0.0.0";
  appId = env[@"SEMUT_APP_ID"] ?: appName;
  NSArray *wh = [(env[@"SEMUT_SIZE"] ?: @"960x640") componentsSeparatedByString:@"x"];
  appSize = NSMakeSize([wh.firstObject doubleValue], [wh.lastObject doubleValue]);
  devMode = [env[@"SEMUT_DEV"] isEqualToString:@"1"];
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);
    inbox = [NSMutableArray array];
    pending = [NSMutableDictionary dictionary];
    configure();
    if (appSize.width < 200 || appSize.height < 150) appSize = NSMakeSize(960, 640);
    if (![NSFileManager.defaultManager fileExistsAtPath:[frontendDir stringByAppendingPathComponent:@"index.html"]]) {
      fprintf(stderr, "semut: no index.html in %s\n", frontendDir.UTF8String);
      return 1;
    }
    if (backendPath && !startServer()) return 1;

    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    delegate = [AppDelegate new];
    app.delegate = delegate;
    spawnBackend();

    // SIGTERM/SIGINT: quit cleanly (the backend goes with us).
    // Dev: SIGUSR1 restarts the backend, SIGUSR2 reloads the page.
    int sigs[] = {SIGTERM, SIGINT, SIGUSR1, SIGUSR2};
    for (int i = 0; i < 4; i++) {
      int s = sigs[i];
      signal(s, SIG_IGN);
      dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, s, 0, dispatch_get_main_queue());
      dispatch_source_set_event_handler(src, ^{
        if (s == SIGUSR1) restartBackend();
        else if (s == SIGUSR2) [delegate reloadPage:nil];
        else [NSApp terminate:nil];
      });
      dispatch_resume(src);
      // Keep the sources alive for the life of the process.
      CFBridgingRetain(src);
    }
    [app run];
  }
  return 0;
}
