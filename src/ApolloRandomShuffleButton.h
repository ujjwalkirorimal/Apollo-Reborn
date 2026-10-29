#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Boost's shuffle FAB, ported: a floating accent-colored shuffle button
// installed on a subreddit screen that was opened through Boost-style random
// discovery. Tapping it resolves ANOTHER random subreddit (same NSFW mode)
// and routes to it in place — the previous random screen is removed from the
// navigation stack underneath the new push, so Back still returns to where
// the user came from. The button hides while the feed scrolls down and
// returns when it scrolls up.
//
// The button is a subview of the posts screen's own view, so its lifetime is
// the screen's: navigating deeper buries it, popping destroys it. Attaching
// twice to one screen is a no-op.
void ApolloRandomShuffleAttach(UIViewController *postsScreen,
                               UINavigationController *nav,
                               BOOL includeNSFW,
                               BOOL useBoostStyle);

// Arm the next random-route push so the legacy /r/random request path also
// receives the shuffle button. replacePrevious is used when the existing
// shuffle button starts another legacy random navigation.
void ApolloRandomShufflePrepareLegacyRoute(UINavigationController *nav,
                                           UIViewController * _Nullable previousScreen,
                                           BOOL includeNSFW,
                                           BOOL replacePrevious);
void ApolloRandomShuffleCancelLegacyRoute(UINavigationController *nav);
void ApolloRandomShuffleDidPushViewController(UINavigationController *nav,
                                              UIViewController *viewController);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
