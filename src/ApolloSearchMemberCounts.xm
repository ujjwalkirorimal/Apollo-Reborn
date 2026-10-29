// ApolloSearchMemberCounts.xm
//
// Boost-style member counts in the Search tab's as-you-type subreddit
// suggestions ("r/AskReddit" gains a trailing "48.1M members").
//
// Structure (per ApolloPostFilters.xm's RE notes, which already manipulates
// this exact table): while typing, _TtC6Apollo20SearchViewController shows
// suggestion rows as bare ApolloDefaultTableViewCell cells whose name label
// is read from the subredditLabel selector, falling back to the stock
// textLabel (which can be nil on these Swift cells — reading only textLabel
// silently matched no rows); the "Posts with …"/"Go to User …" action rows
// always contain whitespace, which real subreddit names never do. The same
// heuristic that lets PostFilters find hide-able rows here lets us find
// count-able rows.
//
// Data comes from the shared ApolloSubredditInfoCache — the same store the
// subreddit headers and link previews use. Cached entries render
// synchronously in the cell; misses fire a requestInfoForSubreddit: fetch
// (the cache coalesces in-flight fetches and keeps a negative cache for dead
// subreddits) and fill the label only if the cell is still showing that
// subreddit after reuse.
//
// UI: a trailing right-aligned value label in the iOS Settings style —
// footnote-size, secondary text color from the active theme's subreddit-list
// palette. Only centerY/trailing/leading constraints are used, so the
// self-sizing row height is untouched and no heightForRow hook is needed.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

// The injected member-count label, lazily created per cell. Association also
// marks the cell as ours so a reused cell's label is reconfigured, not recreated.
static const void *kApolloMemberCountLabelKey = &kApolloMemberCountLabelKey;
// The subreddit the currently displayed label text describes. Completion
// handlers compare against this so a recycled cell never shows a stale count.
static const void *kApolloMemberCountExpectedNameKey = &kApolloMemberCountExpectedNameKey;

static BOOL ApolloMemberCountsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySearchSuggestionMemberCounts];
}

// The label a suggestion cell shows the subreddit name in, plus the bare name
// it contains, or nil for rows that aren't subreddit suggestions. Mirrors
// ApolloPFSubredditNameFromSearchCell (ApolloPostFilters.xm): the cells expose
// subredditLabel as the primary read (the stock textLabel is only a fallback
// there, and can be nil on these Swift cells), and action rows ("Posts with
// …", "Go to User …", the Random rows) always contain whitespace, which real
// subreddit names never do.
static void ApolloMemberCountsNameForCell(UITableViewCell *cell, NSString **outName) {
    *outName = nil;
    if (!cell) return;
    UILabel *nameLabel = nil;
    SEL sel = @selector(subredditLabel);
    if ([cell respondsToSelector:sel]) {
        id l = ((id (*)(id, SEL))objc_msgSend)(cell, sel);
        if ([l isKindOfClass:[UILabel class]]) nameLabel = (UILabel *)l;
    }
    NSString *name = nameLabel.text;
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        nameLabel = cell.textLabel;
        name = nameLabel.text;
    }
    if (![name isKindOfClass:[NSString class]]) return;
    NSString *trimmed =
        [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;
    if ([trimmed rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location
            != NSNotFound) {
        return; // "Posts with …", "Go to User …", the Random action rows
    }
    if ([trimmed hasPrefix:@"r/"] || [trimmed hasPrefix:@"R/"]) {
        trimmed = [trimmed substringFromIndex:2];
    }
    if (trimmed.length == 0) return;
    *outName = trimmed;
}

static void ApolloMemberCountsClearLabel(UITableViewCell *cell) {
    UILabel *label = objc_getAssociatedObject(cell, kApolloMemberCountLabelKey);
    if (label) {
        label.text = nil;
        label.hidden = YES;
    }
    objc_setAssociatedObject(cell, kApolloMemberCountExpectedNameKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UILabel *ApolloMemberCountsLabelForCell(UITableViewCell *cell) {
    UILabel *label = objc_getAssociatedObject(cell, kApolloMemberCountLabelKey);
    if (label) return label;

    label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.adjustsFontForContentSizeCategory = YES;
    label.textAlignment = NSTextAlignmentRight;
    label.textColor = ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    label.hidden = YES;
    // The count must never lose its width: Apollo's cell labels are
    // full-width frames ending at the trailing margin, so any constraint
    // fight between this label's intrinsic width and a clearance constraint
    // resolves by compressing the label to zero width — an invisible label
    // (the original bug). Width is therefore REQUIRED, and the only breakable
    // constraint is the soft left-half boundary below: a very long name may
    // overlap the count cosmetically, but the count never disappears.
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    [cell.contentView addSubview:label];
    // No vertical edge constraints: the label hangs off centerY, so the row's
    // self-sizing height stays exactly Apollo's.
    NSLayoutConstraint *stayInRightHalf =
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:
         cell.contentView.centerXAnchor];
    // Just under required: when the name and the count genuinely collide, the
    // system breaks this boundary (a cosmetic overlap) instead of the count.
    stayInRightHalf.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        stayInRightHalf
    ]];
    objc_setAssociatedObject(cell, kApolloMemberCountLabelKey, label,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return label;
}

%hook _TtC6Apollo20SearchViewController

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    if (!ApolloMemberCountsEnabled()) {
        ApolloMemberCountsClearLabel(cell);
        return cell;
    }

    NSString *name = nil;
    ApolloMemberCountsNameForCell(cell, &name);
    if (!name) {
        ApolloMemberCountsClearLabel(cell);
        return cell;
    }

    objc_setAssociatedObject(cell, kApolloMemberCountExpectedNameKey, name,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    UILabel *label = ApolloMemberCountsLabelForCell(cell);
    ApolloSubredditInfo *info = [[ApolloSubredditInfoCache sharedCache]
        cachedInfoForSubreddit:name];
    if (info && info.subscriberCount >= 0) {
        label.text = ApolloSubredditFormattedMemberCount(info.subscriberCount);
        label.hidden = NO;
        return cell;
    }

    // Unknown yet: hide the label, fetch (coalesced + negatively cached by the
    // store), and fill only if this cell still shows the same subreddit.
    label.hidden = YES;
    __weak UITableViewCell *weakCell = cell;
    NSString *expected = [name copy];
    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:name
        completion:^(ApolloSubredditInfo *fetchedInfo) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!fetchedInfo) return;
                UITableViewCell *strongCell = weakCell;
                if (!strongCell || fetchedInfo.subscriberCount < 0) return;
                NSString *stillShowing = objc_getAssociatedObject(
                    strongCell, kApolloMemberCountExpectedNameKey);
                if (![stillShowing isKindOfClass:[NSString class]] ||
                    [stillShowing caseInsensitiveCompare:expected] != NSOrderedSame) {
                    return;
                }
                UILabel *strongLabel =
                    objc_getAssociatedObject(strongCell, kApolloMemberCountLabelKey);
                if (!strongLabel) return;
                strongLabel.text = ApolloSubredditFormattedMemberCount(fetchedInfo.subscriberCount);
                strongLabel.hidden = NO;
            });
        }];
    return cell;
}

%end

%ctor {
    %init;
}
