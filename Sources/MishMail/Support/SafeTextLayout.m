#import "SafeTextLayout.h"
#import <os/log.h>

BOOL MMEnsureTextLayout(NSLayoutManager *layoutManager,
                        NSTextContainer *textContainer) {
    @try {
        [layoutManager ensureLayoutForTextContainer:textContainer];
        return YES;
    } @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT,
                     "MishMail: text layout raised %{public}@: %{public}@",
                     exception.name, exception.reason);
        return NO;
    }
}
