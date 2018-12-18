//
//  ViewController.m
//  MacOSApp
//
//  Created by zifan.zx on 2018/6/5.
//  Copyright © 2018年 zifan.zx. All rights reserved.
//

#import "ViewController.h"
#import <WeexSDK_MacOS/WXSDKInstance.h>
#import <WeexSDK_MacOS/WXSDKEngine.h>
#import <WeexSDK_MacOS/WXLog.h>
#import <WeexSDK_MacOS/WXImgLoaderProtocol.h>
#import "WXImgLoaderDefaultImpl.h"
#import "WXDTInputComponent.h"

const NSString * viewControllerRenderURL = @"http://dotwe.org/raw/dist/469bd2a313c62ab2d7477b9feab1a5e7.bundle.wx";
@interface ViewController()
@property (nonatomic, strong) WXSDKInstance * instance;
@property (nonatomic, strong) NSView * weexView;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    [self renderView];
}

- (void)viewDidLayout
{
    if (self.instance) {
        self.instance.frame = self.view.frame;
    }
}

- (void)loadView
{
    [WXLog setLogLevel:WXLogLevelAll];
    [WXSDKEngine initSDKEnvironment];
    [WXSDKEngine registerHandler:[WXImgLoaderDefaultImpl new] withProtocol:@protocol(WXImgLoaderProtocol)];
    [WXSDKEngine registerComponent:@"input" withClass:[WXDTInputComponent class]];
    [super loadView];
}

- (void)renderView
{
    self.view.translatesAutoresizingMaskIntoConstraints = NO;
    self.instance = [[WXSDKInstance alloc] init];
    self.instance.frame = self.view.frame;
    __weak typeof(self) weakSelf = self;
    self.instance.onCreate = ^(NSView * rootView) {
        if (weakSelf.weexView.superview) {
            [weakSelf.weexView removeFromSuperview];
            weakSelf.weexView = nil;
        }
        weakSelf.weexView = rootView;
        [weakSelf.view addSubview:weakSelf.weexView];
    };
    self.instance.onFailed = ^(NSError *error) {
        NSLog(@"%@", error);
    };
    [self.instance renderWithURL:[NSURL URLWithString:viewControllerRenderURL]];
}

- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];

    // Update the view, if already loaded.
}


@end
