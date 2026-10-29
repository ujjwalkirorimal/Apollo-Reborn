#import "ApolloRandomSubredditLoadingViewController.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloRandomShuffleButton.h"
#import "ApolloThemeRuntime.h"
#import "Tweak.h"

// Keep in sync with the retry cap in Tweak.xm's ApolloBoostRandomAttempt.
static const NSUInteger kApolloBoostRandomMaxAttempts = 4;

@interface ApolloRandomSubredditLoadingViewController ()
@property(nonatomic, copy) NSString *rowTitle;
@property(nonatomic) BOOL includeNSFW;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *progressLabel;
@property(nonatomic, strong) UILabel *errorLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic) BOOL resolved;
@property(nonatomic) BOOL cancelled;
@end

@implementation ApolloRandomSubredditLoadingViewController

- (instancetype)initWithTitle:(NSString *)title includeNSFW:(BOOL)includeNSFW {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _rowTitle = [title copy];
    _includeNSFW = includeNSFW;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.rowTitle;
    // Keep the tab bar visible: the placeholder lives inside the Search tab's
    // stack, and a YES here would also keep the bar hidden on the subreddit
    // screen the router pushes above this controller.
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;

    _spinner = [[UIActivityIndicatorView alloc] initWithFrame:CGRectZero];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.activityIndicatorViewStyle = UIActivityIndicatorViewStyleLarge;
    _spinner.color = ApolloThemeAccentColor() ?: self.view.tintColor;
    _spinner.hidesWhenStopped = YES;

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.text = _includeNSFW ? @"Finding a random NSFW subreddit…"
                                     : @"Finding a random subreddit…";
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _statusLabel.adjustsFontForContentSizeCategory = YES;
    _statusLabel.textColor = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;

    _progressLabel = [[UILabel alloc] init];
    _progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _progressLabel.text = @"Searching Reddit…";
    _progressLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _progressLabel.adjustsFontForContentSizeCategory = YES;
    _progressLabel.textColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    _progressLabel.numberOfLines = 0;
    _progressLabel.textAlignment = NSTextAlignmentCenter;

    _errorLabel = [[UILabel alloc] init];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _errorLabel.adjustsFontForContentSizeCategory = YES;
    _errorLabel.textColor = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    _errorLabel.numberOfLines = 0;
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.hidden = YES;

    // Classic button API: the tweak keeps an iOS 14 deployment floor, and
    // UIButtonConfiguration would need an availability guard for no gain here.
    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_retryButton setTitle:@"Try Again" forState:UIControlStateNormal];
    _retryButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _retryButton.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    _retryButton.hidden = YES;
    [_retryButton addTarget:self action:@selector(retryTapped)
               forControlEvents:UIControlEventTouchUpInside];

    // Hidden arranged subviews are automatically skipped by UIStackView, so the
    // loading pair and the failure pair simply swap places in one stack.
    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[_spinner, _statusLabel, _progressLabel, _errorLabel, _retryButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:40],
        [self.view.trailingAnchor constraintGreaterThanOrEqualToAnchor:stack.trailingAnchor constant:40]
    ]];

    [self startResolve];
}

#pragma mark - Resolution lifecycle

- (void)startResolve {
    self.cancelled = NO;
    self.resolved = NO;
    self.errorLabel.hidden = YES;
    self.retryButton.hidden = YES;
    self.statusLabel.hidden = NO;
    self.progressLabel.hidden = NO;
    self.progressLabel.text = @"Searching Reddit…";
    [self.spinner startAnimating];

    ApolloLog(@"[BoostRandom] Placeholder resolving a %@subreddit",
              _includeNSFW ? @"NSFW " : @"");
    __weak ApolloRandomSubredditLoadingViewController *weakSelf = self;
    ApolloResolveBoostRandomSubreddit(
        _includeNSFW,
        ^(NSUInteger attemptNumber) {
            ApolloRandomSubredditLoadingViewController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.cancelled || strongSelf.resolved) return;
            strongSelf.progressLabel.text = attemptNumber == 0
                ? @"Searching Reddit…"
                : [NSString stringWithFormat:@"Searching… try %lu of %lu",
                   (unsigned long)attemptNumber + 1,
                   (unsigned long)kApolloBoostRandomMaxAttempts];
        },
        ^(NSString *subreddit, NSError *error) {
            ApolloRandomSubredditLoadingViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.cancelled) return;
            if (subreddit.length > 0) {
                [strongSelf openResolvedSubreddit:subreddit];
                return;
            }
            [strongSelf showFailure:error.localizedDescription ?: @"Couldn't find a random subreddit."];
        });
}

- (void)openResolvedSubreddit:(NSString *)subreddit {
    self.resolved = YES;
    NSURL *url = [NSURL URLWithString:[@"https://reddit.com/r/" stringByAppendingString:subreddit]];
    if (!url || !ApolloRouteResolvedURLViaApolloScheme(url)) {
        self.resolved = NO;
        [self showFailure:@"Apollo's subreddit router was unavailable."];
        return;
    }

    [self.spinner stopAnimating];
    self.progressLabel.text = [NSString stringWithFormat:@"Opening r/%@…", subreddit];
    ApolloLog(@"[BoostRandom] Resolved r/%@; handing off to Apollo's router", subreddit);
    [self removeFromNavigationStackOnceRouterPushSettles];
    [self fireFinished];
}

- (void)showFailure:(NSString *)message {
    [self.spinner stopAnimating];
    self.statusLabel.hidden = YES;
    self.progressLabel.hidden = YES;
    self.errorLabel.text = message;
    self.errorLabel.hidden = NO;
    self.retryButton.hidden = NO;
    ApolloLogError(@"[BoostRandom] %@", message);
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}

- (void)retryTapped {
    [self startResolve];
}

// The router pushed Apollo's subreddit screen on top of this placeholder.
// Drop this controller out from underneath it so Back returns to the Search
// tab instead of to this screen, then install Boost's shuffle FAB on the new
// screen (it only ever appears on random-opened subreddits). Wait for that
// push transition to settle first; removing the outgoing view controller
// mid-transition glitches the navigation bar.
- (void)removeFromNavigationStackOnceRouterPushSettles {
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationController *nav = self.navigationController;
        if (!nav || ![nav.viewControllers containsObject:self]) return;

        void (^remove)(void) = ^{
            UINavigationController *stillNav = self.navigationController;
            if (!stillNav || ![stillNav.viewControllers containsObject:self]) return;
            NSMutableArray<UIViewController *> *stack = [stillNav.viewControllers mutableCopy];
            [stack removeObject:self];
            [stillNav setViewControllers:stack animated:NO];
            UIViewController *newTop = stillNav.topViewController;
            if ([newTop isKindOfClass:ApolloClassPostsViewController]) {
                ApolloRandomShuffleAttach(newTop, stillNav, self->_includeNSFW, YES);
            }
        };

        id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
        if (coordinator) {
            [coordinator animateAlongsideTransition:nil
                completion:^(__attribute__((unused)) id<UIViewControllerTransitionCoordinatorContext> context) {
                    remove();
                }];
        } else {
            remove();
        }
    });
}

#pragma mark - Lifecycle

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // An aborted interactive back-gesture re-shows this controller after
    // viewWillDisappear already marked it cancelled; resume listening to the
    // in-flight resolution so it doesn't dead-end on the spinner.
    if (!self.resolved && self.cancelled) self.cancelled = NO;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Only a real pop (not the router pushing the subreddit on top of us)
    // means the user gave up: drop any in-flight result and release the
    // presenter's re-entry guard. The resolver has no cancellation handle;
    // its remaining attempts are bounded and their result is ignored.
    if (self.isMovingFromParentViewController) {
        self.cancelled = YES;
        [self fireFinished];
    }
}

- (void)dealloc {
    [self fireFinished];
}

- (void)fireFinished {
    if (self.onFinished) self.onFinished();
}

@end
