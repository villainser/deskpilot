#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
NS_ASSUME_NONNULL_BEGIN
NSArray * _Nullable DPSpaces(void);
NSArray * _Nullable DPWindowSpaces(uint32_t window);
uint32_t DPWindowID(AXUIElementRef element);
BOOL DPCanMove(void);
NSString * _Nullable DPBeginMove(uint32_t window, uint64_t target);
void DPEndMove(void);
NS_ASSUME_NONNULL_END
