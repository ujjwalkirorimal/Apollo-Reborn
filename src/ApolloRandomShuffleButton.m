#import "ApolloRandomShuffleButton.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"
#import "ApolloToast.h"
#import "Tweak.h"
#import <math.h>
#import <objc/runtime.h>

// In-flight marker: one resolve at a time per installed button.
static const void *kApolloShuffleAttachedKey = &kApolloShuffleAttachedKey;
// Owns the scroll observer for the lifetime of the button.
static const void *kApolloShuffleObserverKey = &kApolloShuffleObserverKey;
static const void *kApolloShufflePendingLegacyRouteKey = &kApolloShufflePendingLegacyRouteKey;

@interface ApolloShuffleButton : UIButton
@property(nonatomic, copy) void (^action)(ApolloShuffleButton *sender);
// Fired when the button leaves the window (its screen was popped or torn
// down) — the KVO teardown hook. Firing while the observed table is still
// alive makes observer removal ordering a non-issue.
@property(nonatomic, copy) void (^onLeaveWindow)(void);
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UIImageView *shuffleIcon;
@property(nonatomic) BOOL includeNSFW;
@property(nonatomic) BOOL useBoostStyle;
@end

@implementation ApolloShuffleButton
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
    self.layer.cornerRadius = 14;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.25;
    self.layer.shadowRadius = 8;
    self.layer.shadowOffset = CGSizeMake(0, 2);
    self.tintColor = UIColor.whiteColor;
    self.accessibilityLabel = @"Open a Random Subreddit";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    [self addTarget:self action:@selector(performAction)
   forControlEvents:UIControlEventTouchUpInside];

    _shuffleIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"shuffle"]];
    _shuffleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _shuffleIcon.contentMode = UIViewContentModeScaleAspectFit;
    _shuffleIcon.tintColor = UIColor.whiteColor;
    [self addSubview:_shuffleIcon];

    _spinner = [[UIActivityIndicatorView alloc] initWithFrame:CGRectZero];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.activityIndicatorViewStyle = UIActivityIndicatorViewStyleMedium;
    _spinner.color = UIColor.whiteColor;
    _spinner.hidesWhenStopped = YES;
    _spinner.hidden = YES;
    [self addSubview:_spinner];
    [NSLayoutConstraint activateConstraints:@[
        [_shuffleIcon.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_shuffleIcon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_shuffleIcon.widthAnchor constraintEqualToConstant:22],
        [_shuffleIcon.heightAnchor constraintEqualToConstant:22],
        // The button is square and the shuffle glyph is centered, so the
        // loading indicator can take its place without changing the FAB layout.
        [_spinner.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ]];
    return self;
}

- (void)performAction {
    if (self.action) self.action(self);
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window && self.onLeaveWindow) self.onLeaveWindow();
}
@end

// Recursively find the feed's table (an ASTableView / UITableView subclass).
// The posts controller's table ivar name isn't worth a hard dependency; the
// view scan is exact enough for one screen.
static UITableView *ApolloShuffleFindTable(UIView *view) {
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *sub in view.subviews) {
        UITableView *table = ApolloShuffleFindTable(sub);
        if (table) return table;
    }
    return nil;
}

// KVO bridge: content offset → Boost's hide-on-scroll-down / show-on-up.
@interface ApolloShuffleScrollObserver : NSObject
@property(nonatomic, weak) UITableView *observedTable;
@property(nonatomic, weak) ApolloShuffleButton *button;
@property(nonatomic, assign) CGFloat lastOffsetY;
@property(nonatomic, assign) BOOL visible;
- (void)detach;
@end

@implementation ApolloShuffleScrollObserver

- (void)observeValueForKeyPath:(__unused NSString *)keyPath
                      ofObject:(__unused id)object
                        change:(__unused NSDictionary *)change
                       context:(__unused void *)context {
    UITableView *table = self.observedTable;
    if (!table || !NSThread.isMainThread) return;
    CGFloat y = table.contentOffset.y;
    CGFloat delta = y - self.lastOffsetY;
    self.lastOffsetY = y;
    if (fabs(delta) < 1.0) return;
    // Hide while scrolling down, reveal scrolling up or resting at the top.
    BOOL show = delta < 0 || y <= 0;
    if (show == self.visible) return;
    self.visible = show;
    ApolloShuffleButton *button = self.button;
    if (!button) return;
    [UIView animateWithDuration:0.2 animations:^{
        button.alpha = show ? 1.0 : 0.0;
        button.transform = show ? CGAffineTransformIdentity
                                : CGAffineTransformMakeScale(0.8, 0.8);
    } completion:^(__unused BOOL finished) {
        // userInteractionEnabled tracks alpha; the completion guard keeps a
        // mid-animation tap from hitting a nearly invisible button.
        button.userInteractionEnabled = show || button.alpha > 0.5;
    }];
}

- (void)detach {
    UITableView *table = self.observedTable;
    if (!table) return;
    self.observedTable = nil;
    @try {
        [table removeObserver:self forKeyPath:@"contentOffset"];
    } @catch (__unused NSException *exception) {
        ApolloLog(@"[ShuffleFAB] KVO detach raced the table's dealloc; ignored");
    }
}

@end

static void ApolloShuffleSetResolving(ApolloShuffleButton *button, BOOL resolving) {
    button.shuffleIcon.hidden = resolving;
    button.spinner.hidden = !resolving;
    button.accessibilityLabel = resolving
        ? @"Finding a Random Subreddit"
        : @"Open a Random Subreddit";
    if (resolving) {
        [button.spinner startAnimating];
    } else {
        [button.spinner stopAnimating];
    }
    button.userInteractionEnabled = !resolving;
}

// Route to the freshly picked subreddit; once the push settles, drop the
// previous random screen out from underneath (Back returns to Search) and
// attach the FAB to the new screen. Reuses the placeholder's hand-off shape.
static void ApolloRandomShuffleNavigate(ApolloShuffleButton *button,
                                        UIViewController *fromScreen,
                                        UINavigationController *nav,
                                        BOOL includeNSFW) {
    ApolloShuffleSetResolving(button, YES);
    if (!button.useBoostStyle) {
        ApolloRandomShufflePrepareLegacyRoute(nav, fromScreen, includeNSFW, YES);
        NSURL *url = [NSURL URLWithString:includeNSFW
            ? @"https://reddit.com/r/randnsfw"
            : @"https://reddit.com/r/random"];
        if (!url || !ApolloRouteResolvedURLViaApolloScheme(url)) {
            ApolloShuffleSetResolving(button, NO);
            ApolloShowToastWithStyle(@"Couldn't Open Random Subreddit",
                                     @"Apollo's native random subreddit route was unavailable.",
                                     ApolloToastStyleError, nil);
        }
        return;
    }
    ApolloResolveBoostRandomSubreddit(includeNSFW, NULL, ^(NSString *subreddit, NSError *error) {
        if (error || subreddit.length == 0) {
            ApolloShuffleSetResolving(button, NO);
            ApolloShowToastWithStyle(@"Couldn't Find Random Subreddit",
                                     error.localizedDescription ?: @"Try again.",
                                     ApolloToastStyleError, nil);
            return;
        }
        NSURL *url = [NSURL URLWithString:
            [@"https://reddit.com/r/" stringByAppendingString:subreddit]];
        if (!url || !ApolloRouteResolvedURLViaApolloScheme(url)) {
            ApolloShuffleSetResolving(button, NO);
            ApolloShowToastWithStyle(@"Couldn't Open Random Subreddit",
                                     @"Apollo's subreddit router was unavailable.",
                                     ApolloToastStyleError, nil);
            return;
        }

        void (^reinstall)(void) = ^{
            // The new subreddit screen is the stack top now.
            UIViewController *newTop = nav.topViewController;
            NSMutableArray<UIViewController *> *stack =
                [nav.viewControllers mutableCopy];
            // Drop the previous random screen (never the new top).
            NSUInteger fromIndex = fromScreen ? [stack indexOfObject:fromScreen] : NSNotFound;
            if (fromIndex != NSNotFound && fromIndex != stack.count - 1) {
                [stack removeObjectAtIndex:fromIndex];
                [nav setViewControllers:stack animated:NO];
            } else if (fromIndex != NSNotFound) {
                // The route never pushed above the old screen (it navigated
                // elsewhere): restore the button so it stays usable.
                ApolloShuffleSetResolving(button, NO);
                return;
            }
            if ([newTop isKindOfClass:ApolloClassPostsViewController]) {
                ApolloRandomShuffleAttach(newTop, nav, includeNSFW, YES);
            }
        };

        id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
        if (coordinator) {
            [coordinator animateAlongsideTransition:nil
                completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> ctx) {
                    reinstall();
                }];
        } else {
            dispatch_async(dispatch_get_main_queue(), reinstall);
        }
    });
}

void ApolloRandomShuffleAttach(UIViewController *postsScreen,
                               UINavigationController *nav,
                               BOOL includeNSFW,
                               BOOL useBoostStyle) {
    if (![postsScreen isKindOfClass:ApolloClassPostsViewController] || !nav) return;
    if (objc_getAssociatedObject(postsScreen, kApolloShuffleAttachedKey)) return;
    objc_setAssociatedObject(postsScreen, kApolloShuffleAttachedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloShuffleButton *button = [[ApolloShuffleButton alloc] initWithFrame:CGRectZero];
    button.includeNSFW = includeNSFW;
    button.useBoostStyle = useBoostStyle;
    [postsScreen.view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:52],
        [button.heightAnchor constraintEqualToConstant:52],
        [button.trailingAnchor constraintEqualToAnchor:postsScreen.view.safeAreaLayoutGuide.trailingAnchor
                                              constant:-16],
        [button.bottomAnchor constraintEqualToAnchor:postsScreen.view.safeAreaLayoutGuide.bottomAnchor
                                            constant:-16]
    ]];

    // KVO scroll tracking, torn down when the button leaves the window.
    ApolloShuffleScrollObserver *observer = [ApolloShuffleScrollObserver new];
    observer.button = button;
    observer.visible = YES;
    UITableView *table = ApolloShuffleFindTable(postsScreen.viewIfLoaded);
    if (table) {
        observer.observedTable = table;
        observer.lastOffsetY = table.contentOffset.y;
        [table addObserver:observer forKeyPath:@"contentOffset"
                   options:NSKeyValueObservingOptionNew context:NULL];
        button.onLeaveWindow = ^{
            [observer detach];
        };
        // The observer must outlive the table's KVO lifetime; the button owns
        // it, and onLeaveWindow detaches it during teardown.
        objc_setAssociatedObject(button, kApolloShuffleObserverKey, observer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        // No table found (unloaded view or layout surprise): the button simply
        // stays visible — degradation, not breakage.
        ApolloLog(@"[ShuffleFAB] No feed table found on r/%@; scroll hiding disabled",
                  nav.topViewController.title ?: @"?");
    }

    __weak UIViewController *weakScreen = postsScreen;
    button.action = ^(ApolloShuffleButton *sender) {
        // If the host screen is gone (popped mid-resolve), the captured nav
        // still drives the hand-off; fromScreen nil simply skips the stack
        // removal below.
        UIViewController *screen = weakScreen;
        UINavigationController *currentNav = screen.navigationController ?: nav;
        if (!currentNav) return;
        ApolloRandomShuffleNavigate(sender, screen, currentNav, sender.includeNSFW);
    };
}

void ApolloRandomShufflePrepareLegacyRoute(UINavigationController *nav,
                                           UIViewController * _Nullable previousScreen,
                                           BOOL includeNSFW,
                                           BOOL replacePrevious) {
    if (!nav) return;
    NSString *token = NSUUID.UUID.UUIDString;
    objc_setAssociatedObject(nav, kApolloShufflePendingLegacyRouteKey,
        @{ @"token": token,
           @"previous": previousScreen ?: NSNull.null,
           @"includeNSFW": @(includeNSFW),
           @"replacePrevious": @(replacePrevious) },
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UINavigationController *weakNav = nav;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UINavigationController *strongNav = weakNav;
        NSDictionary *pending = objc_getAssociatedObject(
            strongNav, kApolloShufflePendingLegacyRouteKey);
        if ([pending[@"token"] isEqualToString:token]) {
            objc_setAssociatedObject(strongNav, kApolloShufflePendingLegacyRouteKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

void ApolloRandomShuffleCancelLegacyRoute(UINavigationController *nav) {
    if (!nav) return;
    objc_setAssociatedObject(nav, kApolloShufflePendingLegacyRouteKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void ApolloRandomShuffleDidPushViewController(UINavigationController *nav,
                                              UIViewController *viewController) {
    if (!nav || ![viewController isKindOfClass:ApolloClassPostsViewController]) return;
    NSDictionary *pending = objc_getAssociatedObject(
        nav, kApolloShufflePendingLegacyRouteKey);
    if (![pending isKindOfClass:NSDictionary.class]) return;
    objc_setAssociatedObject(nav, kApolloShufflePendingLegacyRouteKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIViewController *previous = pending[@"previous"] == NSNull.null
        ? nil : pending[@"previous"];
    BOOL replacePrevious = [pending[@"replacePrevious"] boolValue];
    BOOL includeNSFW = [pending[@"includeNSFW"] boolValue];
    void (^finish)(void) = ^{
        if (replacePrevious && previous) {
            NSMutableArray<UIViewController *> *stack = [nav.viewControllers mutableCopy];
            NSUInteger previousIndex = [stack indexOfObject:previous];
            if (previousIndex != NSNotFound && previousIndex != stack.count - 1) {
                [stack removeObjectAtIndex:previousIndex];
                [nav setViewControllers:stack animated:NO];
            }
        }
        ApolloRandomShuffleAttach(viewController, nav, includeNSFW, NO);
    };

    id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil
            completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                finish();
            }];
    } else {
        dispatch_async(dispatch_get_main_queue(), finish);
    }
}
