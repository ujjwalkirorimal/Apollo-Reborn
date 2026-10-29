#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Boost-style random-subreddit placeholder. Pushed the instant the user taps
// Random / Random NSFW in the Search tab so the tap has a visible effect
// while the community-search emulation resolves (it can make several network
// attempts). Shows a spinner with per-attempt progress; on success it routes
// the picked subreddit through Apollo's own router and drops itself from the
// navigation stack underneath the pushed subreddit screen; failures surface
// inline with a Try Again button instead of a dead spinner.
@interface ApolloRandomSubredditLoadingViewController : UIViewController

- (instancetype)initWithTitle:(NSString *)title includeNSFW:(BOOL)includeNSFW;

// Fired whenever this controller's job is over — the subreddit was routed,
// the user backed out, or the controller is going away. Idempotent. The
// presenter uses it to clear its re-entry guard on the Search tab.
@property(nonatomic, copy, nullable) void (^onFinished)(void);

@end

NS_ASSUME_NONNULL_END
