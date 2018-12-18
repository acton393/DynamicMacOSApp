//
//  WXDTInputComponent.m
//  MacOSApp
//
//  Created by zifan.zx on 2018/10/16.
//  Copyright © 2018年 zifan.zx. All rights reserved.
//

#import "WXDTInputComponent.h"
#import <WeexSDK_MacOS/WXConvert.h>

@interface WXDTInputComponent()<NSTextFieldDelegate>
@property (nonatomic,assign)NSUInteger numberOfLines;
@end

@implementation WXDTInputComponent

- (instancetype)initWithRef:(NSString *)ref type:(NSString *)type styles:(NSDictionary *)styles attributes:(NSDictionary *)attributes events:(NSArray *)events weexInstance:(WXSDKInstance *)weexInstance
{
    if (self = [super initWithRef:ref type:type styles:styles attributes:attributes events:events weexInstance:weexInstance]) {
        if (attributes[@"lines"]) {
            self.numberOfLines = [WXConvert NSUInteger:attributes[@"lines"]];
        }
    }
    return self;
}

- (void)addEvent:(NSString *)eventName
{
    if ([eventName isEqualToString:@"input"]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controlTextDidBeginEditing:) name:NSControlTextDidBeginEditingNotification object:nil];
    }
    if ([eventName isEqualToString:@"blur"]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controlTextDidEndEditing:) name:NSControlTextDidBeginEditingNotification object:nil];
    }
}

- (NSView *)loadView
{
    return [NSTextField new];
}

- (void)viewDidLoad
{
    NSTextField * textField = (NSTextField*)self.view;
    //some other UI configuration
    textField.maximumNumberOfLines = self.numberOfLines;// single input
    textField.delegate = self;
}

- (void)controlTextDidBeginEditing:(NSNotification *)obj
{
    NSTextView * textFiled = obj.userInfo[@"NSFieldEditor"];
    [self fireEvent:@"input" params:@{@"value":textFiled.string}];
}

- (void)controlTextDidEndEditing:(NSNotification *)obj
{
    NSTextView * textFiled = obj.userInfo[@"NSFieldEditor"];
    [self fireEvent:@"blur" params:@{@"value":textFiled.string}];
}

- (void)dealloc
{
    ((NSTextField*)self.view).delegate = nil;
}

@end
