//
//  MCLog.m
//  MCLog
//
//  Created by Michael Chen on 2014/8/1.
//  Copyright (c) 2014年 Yuhua Chen. All rights reserved.
//

#import "MCLog.h"
#import <objc/runtime.h>
#include <execinfo.h>

#define MCLOG_FLAG "MCLOG_FLAG"
#define kTagSearchField	99

#define MCLogger(fmt, ...) NSLog((@"[MCLog] %s(Line:%d) " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)

@class MCLogIDEConsoleArea;

static NSMutableDictionary *originConsoleItemsMap;
static MCLogIDEConsoleArea *consoleArea = nil;
static NSSearchField       *SearchField = nil;

NSSearchField *getSearchField(id consoleArea);
NSString *hash(id obj);
NSArray *backtraceStack();
void hookDVTTextStorage();
void hookIDEConsoleAdaptor();
void hookIDEConsoleArea();
void hookIDEConsoleItem();


typedef NS_ENUM(NSUInteger, MCLogLevel) {
    MCLogLevelVerbose = 0x1000,
    MCLogLevelInfo,
    MCLogLevelWarn,
    MCLogLevelError
};


////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSSearchField (MCLog)
@interface NSSearchField (MCLog)
@property (nonatomic, strong) MCLogIDEConsoleArea *consoleArea;
@property (nonatomic, strong) NSTextView *consoleTextView;
@end

static const void *kMCLogConsoleTextViewKey;
static const void *kMCLogIDEConsoleAreaKey;

@implementation NSSearchField (MCLog)

- (void)setConsoleArea:(MCLogIDEConsoleArea *)consoleArea
{
	objc_setAssociatedObject(self, &kMCLogIDEConsoleAreaKey, consoleArea, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (MCLogIDEConsoleArea *)consoleArea
{
	return objc_getAssociatedObject(self, &kMCLogIDEConsoleAreaKey);
}

- (void)setConsoleTextView:(NSTextView *)consoleTextView
{
	objc_setAssociatedObject(self, &kMCLogConsoleTextViewKey, consoleTextView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSTextView *)consoleTextView
{
	return objc_getAssociatedObject(self, &kMCLogConsoleTextViewKey);
}

@dynamic consoleArea;
@dynamic consoleTextView;
@end


///////////////////////////////////////////////////////////////////////////////////
#pragma mark - MCIDEConsoleItem

@interface NSObject (MCIDEConsoleItem)
- (void)setLogLevel:(NSUInteger)loglevel;
- (NSUInteger)logLevel;

- (void)updateItemAttribute:(id)item;
@end

static const void *LogLevelAssociateKey;
@implementation NSObject (MCIDEConsoleItem)

- (void)setLogLevel:(NSUInteger)loglevel
{
    objc_setAssociatedObject(self, &LogLevelAssociateKey, @(loglevel), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSUInteger)logLevel
{
    return [objc_getAssociatedObject(self, &LogLevelAssociateKey) unsignedIntegerValue];
}

- (void)updateItemAttribute:(id)item
{
    NSError *error = nil;
    static NSRegularExpression *TimePattern = nil;
    if (TimePattern == nil) {
        TimePattern = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}\\s\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s+.*" options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators error:&error];
        if (!TimePattern) {
            MCLogger(@"%@", error);
        }
    }
    
    static NSRegularExpression *ControlCharsPattern = nil;
    if (ControlCharsPattern == nil) {
        ControlCharsPattern = [NSRegularExpression regularExpressionWithPattern:@"\\\\0?33\\[[\\d;]+m" options:0 error:&error];
        if (!ControlCharsPattern) {
            MCLogger(@"%@", error);
        }
    }
    
    NSString *content = [item valueForKey:@"content"];
    if ([[item valueForKey:@"output"] boolValue] || [[item valueForKey:@"error"] boolValue]) {
        if ([TimePattern matchesInString:content options:0 range:NSMakeRange(0, content.length)].count) {
            //MCLogger(@"%@ matched pattern:'%@'", content, TimePattern);
            //content = [content substringFromIndex:11];
        }
        if ([[item valueForKey:@"error"] boolValue]) {
            content = [NSString stringWithFormat:@"\\033[31m%@\\033[0m", content];
        } else {
            NSString *originalContent = [ControlCharsPattern stringByReplacingMatchesInString:content options:0 range:NSMakeRange(0, content.length) withTemplate:@""];
            static NSString *patternString = @"^\\d{4}-\\d{2}-\\d{2}\\s\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s+.+\\[[\\da-fA-F]+:[\\da-fA-F]+\\]\\s+-\\[%@\\]\\s+.*";
            static NSRegularExpression *VerboseLogPattern   = nil;
            static NSRegularExpression *InfoLogPattern      = nil;
            static NSRegularExpression *WarnLogPattern      = nil;
            static NSRegularExpression *ErrorLogPattern     = nil;
            
            if (!VerboseLogPattern) {
                VerboseLogPattern = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:patternString, @"VERBOSE"] options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators error:&error];
                if (!VerboseLogPattern) {
                    MCLogger(@"%@", error);
                }
            }
            if (!InfoLogPattern) {
                InfoLogPattern = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:patternString, @"INFO"] options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators error:&error];
                if (!InfoLogPattern) {
                    MCLogger(@"%@", error);
                }
            }
            if (!WarnLogPattern) {
                WarnLogPattern = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:patternString, @"WARN"] options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators error:&error];
                if (!WarnLogPattern) {
                    MCLogger(@"%@", error);
                }
            }
            if (!ErrorLogPattern) {
                ErrorLogPattern = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:patternString, @"ERROR"] options:NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators error:&error];
                if (!ErrorLogPattern) {
                    MCLogger(@"%@", error);
                }
            }
            NSRange matchingRange = (NSRange){.location = 0, .length = originalContent.length};
            if ([VerboseLogPattern rangeOfFirstMatchInString:originalContent options:0 range:matchingRange].length == matchingRange.length) {
                [item setLogLevel:MCLogLevelVerbose];
            }
            else if ([InfoLogPattern rangeOfFirstMatchInString:originalContent options:0 range:matchingRange].length == matchingRange.length) {
                [item setLogLevel:MCLogLevelInfo];
            }
            else if ([WarnLogPattern rangeOfFirstMatchInString:originalContent options:0 range:matchingRange].length == matchingRange.length) {
                [item setLogLevel:MCLogLevelWarn];
            }
            else if ([ErrorLogPattern rangeOfFirstMatchInString:originalContent options:0 range:matchingRange].length == matchingRange.length) {
                [item setLogLevel:MCLogLevelError];
            }
        }
    } else {
        //content = [@"\\033[0m" stringByAppendingString:content];
    }
    
    [item setValue:content forKey:@"content"];
}

@end


static IMP IDEConsoleItemInitIMP = nil;
@interface MCIDEConsoleItem : NSObject
- (id)initWithAdaptorType:(id)arg1 content:(id)arg2 kind:(int)arg3;
@end

@implementation MCIDEConsoleItem

- (id)initWithAdaptorType:(id)arg1 content:(id)arg2 kind:(int)arg3
{
    id item = IDEConsoleItemInitIMP(self, _cmd, arg1, arg2, arg3);
    [self updateItemAttribute:item];
    MCLogger(@"log level:%zd", [item logLevel]);
    return item;
}


@end


///////////////////////////////////////////////////////////////////////////////////
#pragma mark - MCLogIDEConsoleArea

@interface MCLogIDEConsoleArea : NSViewController
- (BOOL)_shouldAppendItem:(id)obj;
- (void)_clearText;
@end

static IMP originalClearTextIMP = nil;
@implementation MCLogIDEConsoleArea

- (BOOL)_shouldAppendItem:(id)obj;
{
    MCLogger(@"should append item:[%@]\n%@\nadaptorType:%@; kind:%zd", [obj class], obj, [obj valueForKey:@"adaptorType"], [obj valueForKey:@"kind"]);
    
	NSSearchField *searchField = getSearchField(self);
	if (!searchField) {
		return YES;
	}
	
	if (!searchField.consoleArea) {
		searchField.consoleArea = self;
	}
	
	NSMutableDictionary *originConsoleItems = [originConsoleItemsMap objectForKey:hash(self)];
	if (!originConsoleItems) {
		originConsoleItems = [NSMutableDictionary dictionary];
	}
    
//    if (originConsoleItems[@([obj timestamp])] == nil) {
//       [MCLogIDEConsoleArea updateItemAttribute:obj];
//    }
	
	// store all console items.
	[originConsoleItems setObject:obj forKey:@([obj timestamp])];
	[originConsoleItemsMap setObject:originConsoleItems forKey:hash(self)];
    
	if (![searchField.stringValue length]) {
        NSInteger filterMode = [[self valueForKey:@"filterMode"] intValue];
        if (filterMode >= MCLogLevelVerbose) {
            MCLogger(@"log level:%zd; filter mode:%zd", [obj logLevel], filterMode);
            return [obj logLevel] >= filterMode;
        }
        return YES;
	}
	
	// test with the regular expression
	NSString *content = [obj content];
	NSRange range = NSMakeRange(0, content.length);
	NSError *error;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:searchField.stringValue
																		   options:(NSRegularExpressionCaseInsensitive|NSRegularExpressionDotMatchesLineSeparators)
																			 error:&error];
    if (regex == nil) {
		// display all if with regex is error
        NSLog(@"%s, error:%@", __PRETTY_FUNCTION__, error);
        return YES;
    }
	
    NSArray *matches = [regex matchesInString:content options:0 range:range];	
	if ([matches count]) {
		return YES;
	}

	return NO;
}

- (void)_clearText
{
	originalClearTextIMP(self, _cmd);
	[originConsoleItemsMap removeObjectForKey:hash(self)];
}
@end




///////////////////////////////////////////////////////////////////////////////////
#pragma mark - MCDVTTextStorage
static IMP originalAppendAttributedStringIMP    = nil;
static IMP originalFixAttributesInRangeIMP      = nil;

@interface MCDVTTextStorage : NSTextStorage
- (void)fixAttributesInRange:(NSRange)range;
- (void)appendAttributedString:(NSAttributedString *)attrString;
@end

@implementation MCDVTTextStorage

- (void)appendAttributedString:(NSAttributedString *)attrString
{
    MCLogger(@"self:%@\ntarget:%@", self, SearchField.consoleTextView.textStorage);
    originalAppendAttributedStringIMP(self, _cmd, attrString);
//    if (self == SearchField.consoleTextView.textStorage) {
//        MCLogger(@"target textStorage! append attrString:%@", attrString);
//    }
}

- (void)fixAttributesInRange:(NSRange)range
{
    MCLogger(@"self:%@\ntarget:%@", self, SearchField.consoleTextView.textStorage);
    originalFixAttributesInRangeIMP(self, _cmd, range);
    
//    if (self == SearchField.consoleTextView.textStorage) {
//        MCLogger(@"target textStorage! fix attr:%@", [self.string substringWithRange:range]);
//    }
}

@end

///////////////////////////////////////////////////////////////////////////////////
#pragma mark - MCIDEConsoleAdaptor
static IMP originalOutputForStandardOutputIMP = nil;

@interface MCIDEConsoleAdaptor :NSObject
- (void)outputForStandardOutput:(id)arg1 isPrompt:(BOOL)arg2 isOutputRequestedByUser:(BOOL)arg3;
@end


static const void *kUnProcessedOutputKey;
static const void *kTimerKey;

@interface NSObject (MCIDEConsoleAdaptor)
- (void)setUnprocessedOutput:(NSString *)output;
- (NSString *)unprocessedOutput;

- (void)setTimer:(NSTimer *)timer;
- (NSTimer *)timer;

- (void)timerTimeout:(NSTimer *)timer;
@end

@implementation NSObject (MCIDEConsoleAdaptor)

- (void)setUnprocessedOutput:(NSString *)output
{
    objc_setAssociatedObject(self, &kUnProcessedOutputKey, output, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSString *)unprocessedOutput
{
    return objc_getAssociatedObject(self, &kUnProcessedOutputKey);
}

- (void)setTimer:(NSTimer *)timer
{
    objc_setAssociatedObject(self, &kTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSTimer *)timer
{
    return objc_getAssociatedObject(self, &kTimerKey);
}

- (void)timerTimeout:(NSTimer *)timer
{
    if (self.unprocessedOutput.length > 0) {
        NSArray *args = timer.userInfo;
        originalOutputForStandardOutputIMP(self, _cmd, self.unprocessedOutput, [args[0] boolValue], [args[1] boolValue]);
    }
    self.unprocessedOutput = nil;
}

@end


@implementation MCIDEConsoleAdaptor

- (void)outputForStandardOutput:(id)arg1 isPrompt:(BOOL)arg2 isOutputRequestedByUser:(BOOL)arg3
{
    [self.timer invalidate];
    self.timer = nil;
    
    NSError *error;
    static NSRegularExpression *LogSeperatorPattern = nil;
    if (LogSeperatorPattern == nil) {
        LogSeperatorPattern = [NSRegularExpression regularExpressionWithPattern:@"\\d{4}-\\d{2}-\\d{2}\\s\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s\\S+\\[[\\da-fA-F]+\\:[\\da-fA-F]+\\]\\s" options:NSRegularExpressionCaseInsensitive error:&error];
        if (!LogSeperatorPattern) {
            MCLogger(@"%@", error);
        }
    }
    NSString *unprocessedstring = self.unprocessedOutput;
    NSString *buffer = arg1;
    if (unprocessedstring.length > 0) {
        buffer = [unprocessedstring stringByAppendingString:arg1];
        self.unprocessedOutput = nil;
    }
    
    if (LogSeperatorPattern) {
        NSArray *matches = [LogSeperatorPattern matchesInString:buffer options:0 range:NSMakeRange(0, [buffer length])];
        if (matches.count > 0) {
            NSRange lastMatchingRange = NSMakeRange(NSNotFound, 0);
            for (NSTextCheckingResult *result in matches) {
                
                if (lastMatchingRange.location != NSNotFound) {
                    NSString *logItemData = [buffer substringWithRange:NSMakeRange(lastMatchingRange.location, result.range.location - lastMatchingRange.location)];
                    originalOutputForStandardOutputIMP(self, _cmd, logItemData, arg2, arg3);
                }
                lastMatchingRange = result.range;
            }
            if (lastMatchingRange.location + lastMatchingRange.length < [buffer length]) {
                self.unprocessedOutput = [buffer substringFromIndex:lastMatchingRange.location];
            }
        } else {
            originalOutputForStandardOutputIMP(self, _cmd, buffer, arg2, arg3);
        }
    } else {
        originalOutputForStandardOutputIMP(self, _cmd, arg1, arg2, arg3);
    }
    
    if (self.unprocessedOutput.length > 0) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(timerTimeout:) userInfo:@[ @(arg2), @(arg3) ] repeats:NO];
    }
    
}

@end


///////////////////////////////////////////////////////////////////////////////////////////

@interface MCLog ()<NSTextFieldDelegate>
{
    NSMutableDictionary *workspace;
}
@end

@implementation MCLog

+ (void)load
{
    NSLog(@"%s, env: %s", __PRETTY_FUNCTION__, getenv(MCLOG_FLAG));
    
    if (getenv(MCLOG_FLAG) && !strcmp(getenv(MCLOG_FLAG), "YES")) {
        // alreay installed plugin
        return;
    }
    
    hookDVTTextStorage();
    hookIDEConsoleAdaptor();
    hookIDEConsoleArea();
    hookIDEConsoleItem();
    
    originConsoleItemsMap = [NSMutableDictionary dictionary];
    setenv(MCLOG_FLAG, "YES", 0);
}

+ (void)pluginDidLoad:(NSBundle *)bundle
{
    NSLog(@"%s, %@", __PRETTY_FUNCTION__, bundle);
    static id sharedPlugin = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedPlugin = [[self alloc] init];
    });
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (id)init
{
    self = [super init];
    if (self) {
        workspace = [NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(activate:) name:@"IDEIndexWillIndexWorkspaceNotification" object:nil];
    }
    return self;
}

- (NSView *)getViewByClassName:(NSString *)className andContainerView:(NSView *)container
{
    Class class = NSClassFromString(className);
    for (NSView *subView in container.subviews) {
        if ([subView isKindOfClass:class]) {
            return subView;
        } else {
            NSView *view = [self getViewByClassName:className andContainerView:subView];
            if ([view isKindOfClass:class]) {
                return view;
            }
        }
    }
    return nil;
}

- (NSView *)getParantViewByClassName:(NSString *)className andView:(NSView *)view
{
    NSView *superView = view.superview;
    while (superView) {
        if ([[superView className] isEqualToString:className]) {
            return superView;
        }
        superView = superView.superview;
    }
    
    return nil;
}

- (BOOL)addCustomViews
{
    NSView *contentView = [[NSApp mainWindow] contentView];
    NSView *consoleTextView = [self getViewByClassName:@"IDEConsoleTextView" andContainerView:contentView];
    if (!consoleTextView) {
        return NO;
    }
    
    contentView = [self getParantViewByClassName:@"DVTControllerContentView" andView:consoleTextView];
    NSView *scopeBarView = [self getViewByClassName:@"DVTScopeBarView" andContainerView:contentView];
    if (!scopeBarView) {
        return NO;
    }
    
    NSButton *button = nil;
    NSPopUpButton *filterButton = nil;
    for (NSView *subView in scopeBarView.subviews) {
        if (button && filterButton) break;
        if (button == nil && [[subView className] isEqualToString:@"NSButton"]) {
            button = (NSButton *)subView;
        }
        else if (filterButton == nil && [[subView className] isEqualToString:@"NSPopUpButton"]) {
            filterButton = (NSPopUpButton *)subView;
        }
    }
    
    if (!button) {
        return NO;
    }
    
    if(filterButton) {
        [self filterPopupButton:filterButton addItemWithTitle:@"Verbose" tag:MCLogLevelVerbose];
        [self filterPopupButton:filterButton addItemWithTitle:@"Info" tag:MCLogLevelInfo];
        [self filterPopupButton:filterButton addItemWithTitle:@"Warn" tag:MCLogLevelWarn];
        [self filterPopupButton:filterButton addItemWithTitle:@"Error" tag:MCLogLevelError];
    }
    
    
    if ([scopeBarView viewWithTag:kTagSearchField]) {
        return YES;
    }
    
    NSRect frame = button.frame;
    frame.origin.x -= button.frame.size.width + 205;
    frame.size.width = 200.0;
    frame.size.height -= 2;
    
    NSSearchField *searchField = [[NSSearchField alloc] initWithFrame:frame];
    searchField.autoresizingMask = NSViewMinXMargin;
    searchField.font = [NSFont systemFontOfSize:11.0];
    searchField.delegate = self;
    searchField.consoleTextView = (NSTextView *)consoleTextView;
    searchField.tag = kTagSearchField;
    [searchField.cell setPlaceholderString:@"Regular Expression"];
    [scopeBarView addSubview:searchField];
    
    SearchField = searchField;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(searchFieldDidEndEditing:) name:NSControlTextDidEndEditingNotification object:nil];
    
    return YES;
}

- (void)filterPopupButton:(NSPopUpButton *)popupButton addItemWithTitle:(NSString *)title tag:(NSUInteger)tag
{
    [popupButton addItemWithTitle:title];
    [popupButton itemAtIndex:popupButton.numberOfItems - 1].tag = tag;
}

#pragma mark - Notifications

- (void)searchFieldDidEndEditing:(NSNotification *)notification
{
    if (![[notification object] isMemberOfClass:[NSSearchField class]]) {
        return;
    }
    
    NSSearchField *searchField = [notification object];
    if (![searchField respondsToSelector:@selector(consoleTextView)]) {
        return;
    }
    
    if (![searchField respondsToSelector:@selector(consoleArea)]) {
        return;
    }
    
    NSTextView *consoleTextView = searchField.consoleTextView;
    MCLogIDEConsoleArea *consoleArea = searchField.consoleArea;
    
    // get rid of the annoying 'undeclared selector' warning
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    if ([consoleTextView respondsToSelector:@selector(clearConsoleItems)]) {
        [consoleTextView performSelector:@selector(clearConsoleItems) withObject:nil];
    }
    
    NSMutableDictionary *originConsoleItems = [originConsoleItemsMap objectForKey:hash(consoleArea)];
    NSArray *sortedItems = [[originConsoleItems allValues] sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSTimeInterval a = [obj1 timestamp];
        NSTimeInterval b = [obj2 timestamp];
        if (a > b) {
            return NSOrderedDescending;
        }
        
        if(a < b) {
            return NSOrderedAscending;
        }
        
        return NSOrderedSame;
    }];
    
    
    
    if ([consoleArea respondsToSelector:@selector(_appendItems:)]) {
        [consoleArea performSelector:@selector(_appendItems:) withObject:sortedItems];
    }
#pragma clang diagnostic pop
}

- (void)activate:(NSNotification *)notification {
    
    id IDEIndex = [notification object];
    BOOL isAdded = [[workspace objectForKey:hash(IDEIndex)] boolValue];
    if (isAdded) {
        return;
    }
    if ([self addCustomViews]) {
        [workspace setObject:@(YES) forKey:hash(IDEIndex)];
    }
}

@end

#pragma mark - method hookers

void hookIDEConsoleArea()
{
    Class IDEConsoleArea = NSClassFromString(@"IDEConsoleArea");
    //_shouldAppendItem
    Method shouldAppendItem = class_getInstanceMethod(IDEConsoleArea, @selector(_shouldAppendItem:));
    IMP hookedShouldAppendItemIMP = class_getMethodImplementation([MCLogIDEConsoleArea class], @selector(_shouldAppendItem:));
    method_setImplementation(shouldAppendItem, hookedShouldAppendItemIMP);
    
    //_clearText
    Method clearText = class_getInstanceMethod(IDEConsoleArea, @selector(_clearText));
    originalClearTextIMP = method_getImplementation(clearText);
    IMP newImpl = class_getMethodImplementation([MCLogIDEConsoleArea class], @selector(_clearText));
    method_setImplementation(clearText, newImpl);
}

void hookIDEConsoleItem()
{
    Class IDEConsoleItem = NSClassFromString(@"IDEConsoleItem");
    Method consoleItemInit = class_getInstanceMethod(IDEConsoleItem, @selector(initWithAdaptorType:content:kind:));
    IDEConsoleItemInitIMP = method_getImplementation(consoleItemInit);
    IMP newConsoleItemInit = class_getMethodImplementation([MCIDEConsoleItem class], @selector(initWithAdaptorType:content:kind:));
    method_setImplementation(consoleItemInit, newConsoleItemInit);
}

void hookDVTTextStorage()
{
    Class DVTTextStorage = NSClassFromString(@"DVTTextStorage");
    //appendAttributedString
    Method appendAttributedString = class_getInstanceMethod(DVTTextStorage, @selector(appendAttributedString:));
    originalAppendAttributedStringIMP = method_getImplementation(appendAttributedString);
    IMP newAppendAttributedStringIMP = class_getMethodImplementation([MCDVTTextStorage class], @selector(appendAttributedString:));
    method_setImplementation(appendAttributedString, newAppendAttributedStringIMP);
    
    Method fixAttributesInRange = class_getInstanceMethod(DVTTextStorage, @selector(fixAttributesInRange:));
    originalFixAttributesInRangeIMP = method_getImplementation(fixAttributesInRange);
    IMP newFixAttributesInRangeIMP = class_getMethodImplementation([MCDVTTextStorage class], @selector(fixAttributesInRange:));
    method_setImplementation(fixAttributesInRange, newFixAttributesInRangeIMP);
}

void hookIDEConsoleAdaptor()
{
    Class IDEConsoleAdaptor = NSClassFromString(@"IDEConsoleAdaptor");
    Method outputForStandardOutput = class_getInstanceMethod(IDEConsoleAdaptor, @selector(outputForStandardOutput:isPrompt:isOutputRequestedByUser:));
    originalOutputForStandardOutputIMP = method_getImplementation(outputForStandardOutput);
    IMP newOutputForStandardOutputIMP = class_getMethodImplementation([MCIDEConsoleAdaptor class], @selector(outputForStandardOutput:isPrompt:isOutputRequestedByUser:));
    method_setImplementation(outputForStandardOutput, newOutputForStandardOutputIMP);
}

#pragma mark - util methods
NSSearchField *getSearchField(id consoleArea)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
	if (![consoleArea respondsToSelector:@selector(scopeBarView)]) {
		return nil;
	}
	
	NSView *scopeBarView = [consoleArea performSelector:@selector(scopeBarView) withObject:nil];
	return [scopeBarView viewWithTag:kTagSearchField];
#pragma clang diagnositc pop
}

NSString *hash(id obj)
{
	if (!obj) {
		return nil;
	}
	
    return [NSString stringWithFormat:@"%lx", (long)obj];
}


NSArray *backtraceStack()
{
    void* callstack[128];
    int frames = backtrace(callstack, 128);
    char **symbols = backtrace_symbols(callstack, frames);
    
    int i;
    NSMutableArray *backtrace = [NSMutableArray arrayWithCapacity:frames];
    for (i = 0; i < frames; ++i) {
        NSString *line = [NSString stringWithUTF8String:symbols[i]];
        if (line == nil) {
            break;
        }
        [backtrace addObject:line];
    }
    
    free(symbols);
    
    return backtrace;
}