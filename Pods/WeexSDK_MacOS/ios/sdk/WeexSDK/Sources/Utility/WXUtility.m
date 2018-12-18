/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 * 
 *   http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

#import "WXUtility.h"
#import "WXLog.h"
#import "WXSDKEngine.h"
#import "WXAppConfiguration.h"
#import "WXThreadSafeMutableDictionary.h"
#import "WXRuleManager.h"
#import "WXSDKEngine.h"
#import "WXConvert.h"
#import "WXResourceRequest.h"
#import "WXResourceLoader.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonCrypto.h>
#import <CoreText/CoreText.h>
#import "WXAppMonitorProtocol.h"
#import "WXConfigCenterProtocol.h"
#import "WXTextComponent.h"
#import "WXAssert.h"
#import "WXDefine.h"
#if WEEX_MAC
#import <sys/sysctl.h>
#endif

#define KEY_PASSWORD  @"com.taobao.Weex.123456"
#define KEY_USERNAME_PASSWORD  @"com.taobao.Weex.weex123456"

static BOOL threadSafeCollectionUsingLock = YES;
static BOOL unregisterFontWhenCollision = NO;
static BOOL listSectionRowThreadSafe = YES;
static BOOL useJSCApiForCreateInstance = YES;

void WXPerformBlockOnMainThread(void (^ _Nonnull block)(void))
{
    if (!block) return;
    
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            block();
        });
    }
}

void WXPerformBlockSyncOnMainThread(void (^ _Nonnull block)(void))
{
    if (!block) return;
    
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            block();
        });
    }
}

void WXPerformBlockOnThread(void (^ _Nonnull block)(void), NSThread *thread)
{
    [WXUtility performBlock:block onThread:thread];
}

void WXSwizzleInstanceMethod(Class className, SEL original, SEL replaced)
{
    Method originalMethod = class_getInstanceMethod(className, original);
    Method newMethod = class_getInstanceMethod(className, replaced);
    
    BOOL didAddMethod = class_addMethod(className, original, method_getImplementation(newMethod), method_getTypeEncoding(newMethod));
    if (didAddMethod) {
        class_replaceMethod(className, replaced, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, newMethod);
    }
}

void WXSwizzleInstanceMethodWithBlock(Class class, SEL original, id block, SEL replaced)
{
    Method originalMethod = class_getInstanceMethod(class, original);
    IMP implementation = imp_implementationWithBlock(block);
    
    class_addMethod(class, replaced, implementation, method_getTypeEncoding(originalMethod));
    Method newMethod = class_getInstanceMethod(class, replaced);
    method_exchangeImplementations(originalMethod, newMethod);
}

SEL WXSwizzledSelectorForSelector(SEL selector)
{
    return NSSelectorFromString([NSString stringWithFormat:@"wx_swizzle_%x_%@", arc4random(), NSStringFromSelector(selector)]);
}

CGFloat WXScreenScale(void)
{
    static CGFloat _scale;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if WEEX_MAC
        _scale = [NSScreen mainScreen].backingScaleFactor;
        
#else
        _scale = [UIScreen mainScreen].scale;
#endif
    });
    return _scale;
}

CGFloat WXPixelScale(CGFloat value, CGFloat scaleFactor)
{
    return WXCeilPixelValue(value * scaleFactor);
}

CGFloat WXRoundPixelValue(CGFloat value)
{
    CGFloat scale = WXScreenScale();
    return round(value * scale) / scale;
}

CGFloat WXCeilPixelValue(CGFloat value)
{
    CGFloat scale = WXScreenScale();
    return ceil(value * scale) / scale;
}

CGFloat WXFloorPixelValue(CGFloat value)
{
    CGFloat scale = WXScreenScale();
    return floor(value * scale) / scale;
}

@implementation WXUtility

+ (void)setThreadSafeCollectionUsingLock:(BOOL)usingLock
{
    threadSafeCollectionUsingLock = usingLock;
}

+ (BOOL)threadSafeCollectionUsingLock
{
    return threadSafeCollectionUsingLock;
}

+ (void)setUnregisterFontWhenCollision:(BOOL)value
{
    unregisterFontWhenCollision = value;
}

+ (void)setListSectionRowThreadSafe:(BOOL)value
{
	listSectionRowThreadSafe = value;
}

+ (BOOL)listSectionRowThreadSafe
{
	return listSectionRowThreadSafe;
}

+ (void)setUseJSCApiForCreateInstance:(BOOL)value
{
    useJSCApiForCreateInstance = value;
}

+ (BOOL)useJSCApiForCreateInstance
{
    return useJSCApiForCreateInstance;
}

+ (void)performBlock:(void (^)(void))block onThread:(NSThread *)thread
{
    if (!thread || !block) return;
    
    if ([NSThread currentThread] == thread) {
        block();
    } else {
        [self performSelector:@selector(_performBlock:)
                     onThread:thread
                   withObject:[block copy]
                waitUntilDone:NO];
    }
}

+ (void)_performBlock:(void (^)(void))block
{
    block();
}

+ (NSString*)platform
{
#if WEEX_MAC
    return @"macOS";
#else
    return @"iOS";
#endif
}

#if WEEX_MAC
+ (NSImage *)imageRotated:(float)degrees size:(NSSize)size
{
    
    degrees = fmod(degrees, 360.);
    if (0 == degrees) {
        return self;
    }
    NSSize maxSize;
    if (90. == degrees || 270. == degrees || -90. == degrees || -270. == degrees) {
        maxSize = NSMakeSize(size.height, size.width);
    } else if (180. == degrees || -180. == degrees) {
        maxSize = size;
    } else {
        maxSize = NSMakeSize(20+MAX(size.width, size.height), 20+MAX(size.width, size.height));
    }
    NSAffineTransform *rot = [NSAffineTransform transform];
    [rot rotateByDegrees:degrees];
    NSAffineTransform *center = [NSAffineTransform transform];
    [center translateXBy:maxSize.width / 2. yBy:maxSize.height / 2.];
    [rot appendTransform:center];
    NSImage *image = [[NSImage alloc] initWithSize:maxSize];
    [image lockFocus];
    [rot concat];
    NSRect rect = NSMakeRect(0, 0, size.width, size.height);
    NSPoint corner = NSMakePoint(-size.width / 2., -size.height / 2.);
    [image drawAtPoint:corner fromRect:rect operation:NSCompositeCopy fraction:1.0];
    [image unlockFocus];
    return image;
}

#endif

+ (NSString*)systemVersion
{
#if WEEX_MAC
    return [[NSProcessInfo processInfo] operatingSystemVersionString]?:@"";
#else
    return [[UIDevice currentDevice] systemVersion] ?: @"";
#endif
}

+ (CGRect)deviceScreenRect
{
#if WEEX_MAC
    return [NSScreen mainScreen].frame;
#else
    return [UIScreen mainScreen].bounds;
#endif
}

+ (NSString*)deviceModel
{
#if WEEX_MAC
    size_t len = 0;
    NSString *machine = @"";
    sysctlbyname("hw.model", NULL, &len, NULL, 0);
    if (len) {
        char *model = malloc(len*sizeof(char));
        sysctlbyname("hw.model", model, &len, NULL, 0);
        printf("%s\n", model);
        free(model);
        machine = [NSString stringWithFormat:@"%s",model];
    }
    return machine;
#else
    return [[UIDevice currentDevice] model]?:@"";
#endif
}

+ (NSDictionary *)getEnvironment
{
    
    NSString *platform = [WXUtility platform];
    NSString *sysVersion = [WXUtility systemVersion];
    NSString *weexVersion = WX_SDK_VERSION;
    NSString *machine = [self deviceName] ? : @"";
    NSString *appVersion = [WXAppConfiguration appVersion] ? : @"";
    NSString *appName = [WXAppConfiguration appName] ? : @"";
    
    CGFloat deviceWidth = [self portraitScreenSize].width;
    CGFloat deviceHeight = [self portraitScreenSize].height;
    CGFloat scale = WXScreenScale();
    
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithDictionary:@{
                                    @"platform":platform,
                                    @"osName":platform, //osName is eaqual to platorm name in native
                                    @"osVersion":sysVersion,
                                    @"weexVersion":weexVersion,
                                    @"deviceModel":machine,
                                    @"appName":appName,
                                    @"appVersion":appVersion,
                                    @"deviceWidth":@(deviceWidth * scale),
                                    @"deviceHeight":@(deviceHeight * scale),
                                    @"scale":@(scale),
                                    @"logLevel":[WXLog logLevelString] ?: @"error"
                                }];
#if !WEEX_MAC
    if ([[[UIDevice currentDevice] systemVersion] integerValue] >= 11) {
        id configCenter = [WXSDKEngine handlerForProtocol:@protocol(WXConfigCenterProtocol)];
        if ([configCenter respondsToSelector:@selector(configForKey:defaultValue:isDefault:)]) {
            // update
            BOOL isDefault = YES;
            BOOL jsfmEnableNativePromiseOnIOS11AndLater = [[configCenter configForKey:@"iOS_weex_ext_config.jsfmEnableNativePromiseOnIOS11AndLater" defaultValue:@(NO) isDefault:&isDefault] boolValue];
            if (!isDefault) {
                // has this config explicitly
                data[@"__enable_native_promise__"] = @(jsfmEnableNativePromiseOnIOS11AndLater);
            }
        }
    }
#endif
    
    if ([WXSDKEngine customEnvironment]) {
        [data addEntriesFromDictionary:[WXSDKEngine customEnvironment]];
    }
    
    return data;
}

+ (NSDictionary *)getDebugEnvironment {
    NSString *platform = @"iOS";
    NSString *weexVersion = [WXSDKEngine SDKEngineVersion];
    NSString *machine = [self registeredDeviceName] ? : @"";
    NSString *appName = [WXAppConfiguration appName] ? : @"";
    NSString *deviceID = [self getDeviceID];
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithDictionary:@{
                                                            @"platform":platform,
                                                            @"weexVersion":weexVersion,
                                                            @"model":machine,
                                                            @"name":appName,
                                                            @"deviceId":deviceID,
                                                        }];
    return data;
}

+ (NSString *)userAgent
{
    // Device UA
    NSString *deviceUA = [NSString stringWithFormat:@"%@(%@/%@)", [self deviceName]?:@"UNKNOWN",[WXUtility platform], [WXUtility systemVersion]?:@"0.0.0"];
    
    // App UA
    NSString *appUA = [NSString stringWithFormat:@"%@(%@/%@)", [WXAppConfiguration appGroup]?:@"WeexGroup", [WXAppConfiguration appName]?:@"WeexApp", [WXAppConfiguration appVersion]?:@"0.0.0"];

    // Weex UA
    NSString *weexUA = [NSString stringWithFormat:@"Weex/%@", WX_SDK_VERSION];
    
    // external UA
    NSString *externalUA = [WXAppConfiguration externalUserAgent] ? [NSString stringWithFormat:@" %@", [WXAppConfiguration externalUserAgent]] : @"";
    
    // Screen Size
#if WEEX_MAC
      CGFloat w = [[NSScreen mainScreen] frame].size.width;
      CGFloat h = [[NSScreen mainScreen] frame].size.height;
    
#else
    CGFloat w = [[UIScreen mainScreen] bounds].size.width;
    CGFloat h = [[UIScreen mainScreen] bounds].size.height;
#endif
    CGFloat s = WXScreenScale();
    NSString * screenUA = [NSString stringWithFormat:@"%dx%d", (int)(s * w), (int)(s * h)];
    
    // New UA
    return [NSString stringWithFormat:@"%@ %@ %@%@ %@", deviceUA, appUA, weexUA, externalUA, screenUA];
}

+ (id)objectFromJSON:(NSString *)json
{
    // in weex there are cases that json is empty container
    if ([json isEqualToString:@"{}"]) return @{}.mutableCopy;
    if ([json isEqualToString:@"[]"]) return @[].mutableCopy;
    return [self JSONObject:[json dataUsingEncoding:NSUTF8StringEncoding] error:nil];
}

+ (id)JSONObject:(NSData*)data error:(NSError **)error
{
    if (!data) return nil;
    id jsonObj = nil;
    @try {
        jsonObj = [NSJSONSerialization JSONObjectWithData:data
                                                  options:NSJSONReadingAllowFragments | NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves
                                                    error:error];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:WX_ERROR_DOMAIN code:-1 userInfo:@{NSLocalizedDescriptionKey: [exception description]}];
        }
    }
    return jsonObj;
}

+ (NSString *)JSONString:(id)object
{
    if(!object) return nil;
    
    @try {
    
        NSError *error = nil;
        if ([object isKindOfClass:[NSArray class]] || [object isKindOfClass:[NSDictionary class]]) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
            if (error) {
                WXLogError(@"%@", [error description]);
                return nil;
            }
            
            return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        } else if ([object isKindOfClass:[NSString class]]) {
            NSArray *array = @[object];
            NSData *data = [NSJSONSerialization dataWithJSONObject:array
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&error];
            if (error) {
                WXLogError(@"%@", [error description]);
                return nil;
            }
            
            NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (string.length <= 4) {
                WXLogError(@"json convert length less than 4 chars.");
                return nil;
            }
            
            return [string substringWithRange:NSMakeRange(2, string.length - 4)];
        } else {
            WXLogError(@"object isn't avaliable class");
            return nil;
        }
        
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (id)copyJSONObject:(id)object
{
    if ([object isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)object;
        NSMutableArray *copyObjs = [NSMutableArray array];
        
        [array enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            id copyObj = [self copyJSONObject:obj];
            [copyObjs insertObject:copyObj atIndex:idx];
        }];
        
        return copyObjs;
    } else if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        NSMutableDictionary *copyObjs = [NSMutableDictionary dictionary];
        
        [dict enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
            id copyObj = [self copyJSONObject:obj];
            [copyObjs setObject:copyObj forKey:key];
        }];
        
        return copyObjs;
    } else {
        return [object copy];
    }
}

+ (BOOL)isBlankString:(NSString *)string {
    
    if (string == nil || string == NULL || [string isKindOfClass:[NSNull class]]) {
        return true;
    }
    if (![string isKindOfClass:[NSString class]]) {
        WXLogError(@"%@ is not a string", string);
        return true;
    }
    if ([[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0) {
        return true;
    }
    
    return false;
}

+ (BOOL)isValidPoint:(CGPoint)point
{
    return !(isnan(point.x)) && !(isnan(point.y));
}

+ (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message
{
    message = message ? : @"";
    return [NSError errorWithDomain:@"WeexErrorDomain" code:code userInfo:@{@"errMsg":message}];
}

+ (NSDictionary *)linearGradientWithBackgroundImage:(NSString *)backgroundImage
{
    NSMutableDictionary * linearGradient = nil;
    if ([backgroundImage hasPrefix:@"linear-gradient"] && [backgroundImage hasSuffix:@")"] ) {
        backgroundImage = [backgroundImage stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSRange range = NSMakeRange(16, backgroundImage.length - 17);
        NSString *str = [backgroundImage substringWithRange:range];
        NSArray *array = [str componentsSeparatedByString:@","];
        WXGradientType gradientType = WXGradientTypeToTop;
        UIColor *startColor, *endColor;
        if ([array count] < 3) {
            return linearGradient;
        }
        if ([array count] == 3) {
            gradientType = [WXConvert gradientType:array[0]];
            startColor = [WXConvert UIColor:array[1]];
            endColor = [WXConvert UIColor:array[2]];
        } else if ([array count] > 3) {
            NSString *gradientTypeStr = array[0];
            NSString *subStr = [str substringFromIndex:gradientTypeStr.length + 1];
            if ([subStr hasPrefix:@"rgb"]) {
                gradientType = [WXConvert gradientType:gradientTypeStr];
                
                if ([subStr containsString:@"%"]) {
                    range = [subStr rangeOfString:@"%"];
                } else {
                    range = [subStr rangeOfString:@")"];
                }
                NSString *startColorStr = [subStr substringToIndex:range.location + 1];
                NSString *endColorStr = [subStr substringFromIndex:range.location + 2];
                startColor = [WXConvert UIColor:startColorStr];
                endColor = [WXConvert UIColor:endColorStr];
            }
            else {
                gradientType = [WXConvert gradientType:gradientTypeStr];
                
                startColor = [WXConvert UIColor:array[1]];
                
                NSString *startColorStr = array[1];
                NSString *endColorStr = [subStr substringFromIndex:startColorStr.length + 1];
                endColor = [WXConvert UIColor:endColorStr];
            }
        }
        
        if (endColor || startColor) {
            linearGradient = [NSMutableDictionary new];
            [linearGradient setValue:startColor forKey:@"startColor"];
            [linearGradient setValue:endColor forKey:@"endColor"];
            [linearGradient setValue:@(gradientType) forKey:@"gradientType"];
        }
    }
    return linearGradient;
}

+ (CAGradientLayer *)gradientLayerFromColors:(NSArray*)colors locations:(NSArray*)locations frame:(CGRect)frame gradientType:(WXGradientType)gradientType
{
    CAGradientLayer * gradientLayer = [CAGradientLayer layer];
    NSMutableArray *newColors = [NSMutableArray new];
    for(UIColor *color in colors) {
        [newColors addObject:(id)color.CGColor];
    }
    if (colors) {
        gradientLayer.colors = newColors;
    }
    if (locations) {
        gradientLayer.locations = locations;
    }
    CGPoint start = CGPointZero;
    CGPoint end = CGPointZero;
    switch (gradientType) {
        case WXGradientTypeToTop:
            start = CGPointMake(0.0, 1.0);
            end = CGPointMake(0.0, 0.0);
            break;
        case WXGradientTypeToBottom:
            start = CGPointMake(0.0, 0.0);
            end = CGPointMake(0.0, 1.0);
            break;
        case WXGradientTypeToLeft:
            start = CGPointMake(1.0, 0.0);
            end = CGPointMake(0.0, 0.0);
            break;
        case WXGradientTypeToRight:
            start = CGPointMake(0.0, 0.0);
            end = CGPointMake(1.0, 0.0);
            break;
        case WXGradientTypeToTopleft:
            start = CGPointMake(1.0, 1.0);
            end = CGPointMake(0.0, 0.0f);
            break;
        case WXGradientTypeToBottomright:
            start = CGPointMake(0.0, 0.0);
            end = CGPointMake(1.0, 1.0);
            break;
        default:
            break;
    }
    
    gradientLayer.startPoint = start;
    gradientLayer.endPoint = end;
    gradientLayer.frame = frame;
    
    return gradientLayer;
}

+ (UIFont *)fontWithSize:(CGFloat)size textWeight:(CGFloat)textWeight textStyle:(WXTextStyle)textStyle fontFamily:(NSString *)fontFamily
{
    return [self fontWithSize:size textWeight:textWeight textStyle:textStyle fontFamily:fontFamily scaleFactor:[self defaultPixelScaleFactor]];
}

+ (UIFont *)fontWithSize:(CGFloat)size textWeight:(CGFloat)textWeight textStyle:(WXTextStyle)textStyle fontFamily:(NSString *)fontFamily scaleFactor:(CGFloat)scaleFactor useCoreText:(BOOL)useCoreText
{
    CGFloat fontSize = (isnan(size) || size == 0) ?  32 * scaleFactor : size;
    UIFont *font = nil;
    
    WXThreadSafeMutableDictionary *fontFace = [[WXRuleManager sharedInstance] getRule:@"fontFace"];
    WXThreadSafeMutableDictionary *fontFamilyDic = fontFace[fontFamily];
    if (fontFamilyDic[@"localSrc"]){
        NSString *fpath = [((NSURL*)fontFamilyDic[@"localSrc"]) path];
        if ([self isFileExist:fpath]) {
            // if the font file is not the correct font file. it will crash by singal 9
            CFURLRef fontURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (__bridge CFStringRef)fpath, kCFURLPOSIXPathStyle, false);
            if (fontURL) {
                if (useCoreText) {
                    CGDataProviderRef fontDataProvider = CGDataProviderCreateWithURL(fontURL);
                    if (fontDataProvider) {
                        CGFontRef newFont = CGFontCreateWithDataProvider(fontDataProvider);
                        if (unregisterFontWhenCollision) {
                            CFErrorRef error = nil;
                            CTFontManagerRegisterGraphicsFont(newFont, &error);
                            // the same font family, remove it and register new one.
                            if (error) {
                                CTFontManagerUnregisterGraphicsFont(newFont, NULL);
                                CTFontManagerRegisterGraphicsFont(newFont, NULL);
                                CFRelease(error);
                            }
                        }
                        else {
                            CTFontManagerRegisterGraphicsFont(newFont, NULL);
                        }
                        fontFamily = (__bridge_transfer  NSString*)CGFontCopyPostScriptName(newFont);
                        CGFontRelease(newFont);
                        CFRelease(fontURL);
                        CFRelease(fontDataProvider);
                    }
                } else {
                    if (unregisterFontWhenCollision) {
                        CFErrorRef error = nil;
                        CTFontManagerRegisterFontsForURL(fontURL, kCTFontManagerScopeProcess, &error);
                        if (error) {
                            CTFontManagerUnregisterFontsForURL(fontURL, kCTFontManagerScopeProcess, NULL);
                            CTFontManagerRegisterFontsForURL(fontURL, kCTFontManagerScopeProcess, NULL);
                            CFRelease(error);
                        }
                    }
                    else {
                        CTFontManagerRegisterFontsForURL(fontURL, kCTFontManagerScopeProcess, NULL);
                    }
                    NSArray *descriptors = (__bridge_transfer NSArray *)CTFontManagerCreateFontDescriptorsFromURL(fontURL);
                    // length of descriptors here will be only one.
                    for (UIFontDescriptor *desc in descriptors) {
                        font = [UIFont fontWithDescriptor:desc size:fontSize];
                    }
                    CFRelease(fontURL);
                }
            }
        }else {
            [[WXRuleManager sharedInstance] removeRule:@"fontFace" rule:@{@"fontFamily": fontFamily}];
        }
    }
    if (!font) {
        if (fontFamily) {
            font = [UIFont fontWithName:fontFamily size:fontSize];
        }
        if (!font) {
            if (fontFamily) {
                WXLogWarning(@"Unknown fontFamily:%@", fontFamily);
            }
            if(WX_SYS_VERSION_LESS_THAN(@"8.2")) {
                font = [UIFont systemFontOfSize:fontSize];
            } else {
                font = [UIFont systemFontOfSize:fontSize weight:textWeight];
            }
        }
    }
    UIFontDescriptor *fontD = font.fontDescriptor;
    UIFontDescriptorSymbolicTraits traits = 0;
    
    traits = (textStyle == WXTextStyleItalic) ? (traits | UIFontDescriptorTraitItalic) : traits;
    if (WX_SYS_VERSION_LESS_THAN(@"8.2")) {
        traits = ((textWeight-0.4) >= 0.0) ? (traits | UIFontDescriptorTraitBold) : traits;
    }else {
        traits = (textWeight-UIFontWeightBold >= 0.0) ? (traits | UIFontDescriptorTraitBold) : traits;
    }
    if (traits != 0) {
        fontD = [fontD fontDescriptorWithSymbolicTraits:traits];
        UIFont *tempFont = [UIFont fontWithDescriptor:fontD size:0];
        if (tempFont) {
            font = tempFont;
        }
    }
    
    return font;
}

+ (UIFont *)fontWithSize:(CGFloat)size textWeight:(CGFloat)textWeight textStyle:(WXTextStyle)textStyle fontFamily:(NSString *)fontFamily scaleFactor:(CGFloat)scaleFactor
{
    return [self fontWithSize:size textWeight:textWeight textStyle:textStyle fontFamily:fontFamily scaleFactor:scaleFactor useCoreText:NO];
}

+ (void)getIconfont:(NSURL *)url completion:(void(^)(NSURL *url, NSError *error))completionBlock
{
    if ([url isFileURL]) {
        // local file url
        NSError * error = nil;
        if (![WXUtility isFileExist:url.path]) {
            error = [NSError errorWithDomain:WX_ERROR_DOMAIN code:-1 userInfo:@{@"errMsg":[NSString stringWithFormat:@"local font %@ is't exist", url.absoluteString]}];
        }
        completionBlock(url, error);
        return;
    }
    
    WXResourceRequest *request = [WXResourceRequest requestWithURL:url resourceType:WXResourceTypeFont referrer:@"" cachePolicy:NSURLRequestUseProtocolCachePolicy];
    
    request.userAgent = [self userAgent];
    WXResourceLoader *iconfontLoader = [[WXResourceLoader alloc] initWithRequest:request];
    iconfontLoader.onFinished = ^(const WXResourceResponse * response, NSData * data) {
        NSURL * downloadPath = nil;
        NSError * error = nil;
        NSHTTPURLResponse * httpResponse = (NSHTTPURLResponse*)response;
        if (200 == httpResponse.statusCode) {
            NSString *file = [NSString stringWithFormat:@"%@/%@",WX_FONT_DOWNLOAD_DIR,[WXUtility md5:[url absoluteString]]];
            downloadPath = [NSURL fileURLWithPath:file];
            NSFileManager *mgr = [NSFileManager defaultManager];
            
            if (![mgr fileExistsAtPath:[file stringByDeletingLastPathComponent]]) {
                // create font cache directory and its parent if not exist
                [mgr createDirectoryAtPath:[file stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&error];
            }
            
            BOOL result = [data writeToFile:downloadPath.path atomically:NO];
            if (!result) {
                downloadPath = nil;
            }
        } else {
            if (200 != httpResponse.statusCode) {
                error = [NSError errorWithDomain:WX_ERROR_DOMAIN code:-1 userInfo:@{@"ErrorMsg": [NSString stringWithFormat:@"can not load the font url %@ ", url.absoluteString]}];
            }
        }
        completionBlock(downloadPath, error);

    };
    
    iconfontLoader.onFailed = ^(NSError* error) {
        completionBlock(nil, error);
    };
    
    [iconfontLoader start];
}

+ (BOOL)isFileExist:(NSString *)filePath
{
    return [[NSFileManager defaultManager] fileExistsAtPath:filePath];
}

+ (NSString *)documentDirectory
{
    static NSString *docPath = nil;
    if (!docPath){
        docPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    }
    return docPath;
}

+ (NSString *)cacheDirectory
{
    static NSString *cachePath = nil;
    if (!cachePath) {
        cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    }
    return cachePath;
}

+ (NSString *)libraryDirectory
{
    static NSString *libPath = nil;
    if (!libPath) {
        libPath = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    }
    return libPath;
}

+ (NSCache *)globalCache
{
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.totalCostLimit = 5 * 1024 * 1024;
#if !WEEX_MAC
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            [cache removeAllObjects];
        }];
#endif
    });
    return cache;
}

+ (NSString *)deviceName
{
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *machine = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    return machine;
}

+ (NSString *)registeredDeviceName
{
    NSString *machine = [WXUtility deviceModel];
    NSString *systemVer = [WXUtility systemVersion];
    NSString *model = [NSString stringWithFormat:@"%@:%@",machine,systemVer];
    return model;
}

+ (CGSize)portraitScreenSize
{
#if !WEEX_MAC
    if ([[UIDevice currentDevice].model isEqualToString:@"iPad"]) {
        return [UIScreen mainScreen].bounds.size;
    }
#endif
    static CGSize portraitScreenSize;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if WEEX_MAC
        CGSize screenSize = [NSScreen mainScreen].frame.size;
#else
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
#endif
        
        portraitScreenSize = CGSizeMake(MIN(screenSize.width, screenSize.height),
                                        MAX(screenSize.width, screenSize.height));
    });
    
    return portraitScreenSize;
}

+ (CGFloat)defaultPixelScaleFactor
{
#if !WEEX_MAC
    if ([[UIDevice currentDevice].model isEqualToString:@"iPad"]) {
        return [self portraitScreenSize].width / WXDefaultScreenWidth;
    }
#endif
    static CGFloat defaultScaleFactor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaultScaleFactor = [self portraitScreenSize].width / WXDefaultScreenWidth;
    });
    
    return defaultScaleFactor;
}


#pragma mark - get deviceID
+ (NSString *)getDeviceID {
    NSMutableDictionary *usernamepasswordKVPairs = (NSMutableDictionary *)[self load:KEY_USERNAME_PASSWORD];
    NSString *deviceID = [usernamepasswordKVPairs objectForKey:KEY_PASSWORD];
    if (!deviceID) {
        CFUUIDRef uuid = CFUUIDCreate(NULL);
        deviceID = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
        assert(deviceID);
        CFRelease(uuid);
        NSMutableDictionary *usernamepasswordKVPairs = [NSMutableDictionary dictionary];
        [usernamepasswordKVPairs setObject:deviceID forKey:KEY_PASSWORD];
        [self save:KEY_USERNAME_PASSWORD data:usernamepasswordKVPairs];
    }
    return deviceID;
}

+ (NSMutableDictionary *)getKeychainQuery:(NSString *)service {
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:
            (id)kSecClassGenericPassword,(id)kSecClass,
            service, (id)kSecAttrService,
            service, (id)kSecAttrAccount,
            (id)kSecAttrAccessibleAfterFirstUnlock,(id)kSecAttrAccessible,
            nil];
}

+ (void)save:(NSString *)service data:(id)data {
    //Get search dictionary
    NSMutableDictionary *keychainQuery = [self getKeychainQuery:service];
    //Delete old item before add new item
    SecItemDelete((CFDictionaryRef)keychainQuery);
    //Add new object to search dictionary(Attention:the data format)
    [keychainQuery setObject:[NSKeyedArchiver archivedDataWithRootObject:data] forKey:(id)kSecValueData];
    //Add item to keychain with the search dictionary
    SecItemAdd((CFDictionaryRef)keychainQuery, NULL);
}

+ (id)load:(NSString *)service {
    id ret = nil;
    NSMutableDictionary *keychainQuery = [self getKeychainQuery:service];
    //Configure the search setting
    //Since in our simple case we are expecting only a single attribute to be returned (the password) we can set the attribute kSecReturnData to kCFBooleanTrue
    [keychainQuery setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnData];
    [keychainQuery setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];
    CFDataRef keyData = NULL;
    if (SecItemCopyMatching((CFDictionaryRef)keychainQuery, (CFTypeRef *)&keyData) == noErr) {
        @try {
            ret = [NSKeyedUnarchiver unarchiveObjectWithData:(__bridge NSData *)keyData];
        } @catch (NSException *e) {
            NSLog(@"Unarchive of %@ failed: %@", service, e);
        } @finally {
        }
    }
    if (keyData)
        CFRelease(keyData);
    return ret;
}

+ (void)delete:(NSString *)service {
    NSMutableDictionary *keychainQuery = [self getKeychainQuery:service];
    SecItemDelete((CFDictionaryRef)keychainQuery);
}

+ (NSURL *)urlByDeletingParameters:(NSURL *)url
{
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    components.query = nil;     // remove the query
    components.fragment = nil;
    return [components URL];
}

+ (NSString *)stringWithContentsOfFile:(NSString *)filePath
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        NSString *contents = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:NULL];
        if (contents) {
            return contents;
        }
    }
    return nil;
}

+ (NSString *)md5:(NSString *)string
{
    const char *str = string.UTF8String;
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), result);
    
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0], result[1], result[2], result[3],
            result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11],
            result[12], result[13], result[14], result[15]
            ];
}

+ (NSString *)uuidString
{
    CFUUIDRef uuidRef = CFUUIDCreate(NULL);
    CFStringRef uuidStringRef= CFUUIDCreateString(NULL, uuidRef);
    NSString *uuid = [NSString stringWithString:(__bridge NSString *)uuidStringRef];
    CFRelease(uuidRef);
    CFRelease(uuidStringRef);
    
    return [uuid lowercaseString];
}

+ (NSDate *)dateStringToDate:(NSString *)dateString
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init] ;
    [formatter setDateFormat:@"yyyy-MM-dd"];
    NSDate *date=[formatter dateFromString:dateString];
    return date;
}

+ (NSDate *)timeStringToDate:(NSString *)timeString
{
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init] ;
    [formatter setDateFormat:@"HH:mm"];
    NSDate *date=[formatter dateFromString:timeString];
    return date;
}

+ (NSString *)dateToString:(NSDate *)date
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd"];
    NSString *str = [dateFormatter stringFromDate:date];
    return str;
}

+ (NSString *)timeToString:(NSDate *)date
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"HH:mm"];
    NSString *str = [dateFormatter stringFromDate:date];
    return str;
}

+ (NSUInteger)getSubStringNumber:(NSString *_Nullable)string subString:(NSString *_Nullable)subString
{
    if([string length] ==0) {
        return 0;
    }
    if([subString length] ==0) {
        return 0;
    }
    NSError *error = NULL;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:subString options:NSRegularExpressionCaseInsensitive error:&error];
    NSUInteger numberOfMatches = [regex numberOfMatchesInString:string options:0 range:NSMakeRange(0, [string length])];
    return numberOfMatches;
    
}

BOOL WXFloatEqual(CGFloat a, CGFloat b) {
    return WXFloatEqualWithPrecision(a, b,FLT_EPSILON);
}
BOOL WXFloatEqualWithPrecision(CGFloat a, CGFloat b ,double precision){
    return fabs(a - b) <= precision;
}
BOOL WXFloatLessThan(CGFloat a, CGFloat b) {
    return WXFloatLessThanWithPrecision(a, b, FLT_EPSILON);
}
BOOL WXFloatLessThanWithPrecision(CGFloat a, CGFloat b ,double precision){
    return a-b < - precision;
}

BOOL WXFloatGreaterThan(CGFloat a, CGFloat b) {
    return WXFloatGreaterThanWithPrecision(a, b, FLT_EPSILON);
}
BOOL WXFloatGreaterThanWithPrecision(CGFloat a, CGFloat b ,double precision){
    return a-b > precision;
}
#if !WEEX_MAC
+ (NSString *_Nullable)returnKeyType:(UIReturnKeyType)type
{
    NSString *typeStr = @"default";
    switch (type) {
        case UIReturnKeyDefault:
            typeStr = @"default";
            break;
        case UIReturnKeyGo:
            typeStr = @"go";
            break;
        case UIReturnKeyNext:
            typeStr = @"next";
            break;
        case UIReturnKeySearch:
            typeStr = @"search";
            break;
        case UIReturnKeySend:
            typeStr = @"send";
            break;
        case UIReturnKeyDone:
            typeStr = @"done";
            break;
            
        default:
            break;
    }
    return typeStr;
}
#endif

+ (void)customMonitorInfo:(WXSDKInstance *_Nullable)instance key:(NSString * _Nonnull)key value:(id _Nonnull)value
{
    if([self isBlankString:key]||!value||!instance){
        return ;
    }
    if(!instance.userInfo){
        instance.userInfo = [NSMutableDictionary new];
    }
    NSMutableDictionary *custormMonitorDict = instance.userInfo[WXCUSTOMMONITORINFO];
    if(!custormMonitorDict){
        custormMonitorDict = [NSMutableDictionary new];
    }
    [custormMonitorDict setObject:value forKey:key];
    instance.userInfo[WXCUSTOMMONITORINFO] = custormMonitorDict;
}

+ (NSDictionary *_Nonnull)dataToBase64Dict:(NSData *_Nullable)data
{
    NSMutableDictionary *dataDict = [NSMutableDictionary new];
    if(data){
        NSString *base64Encoded = [data base64EncodedStringWithOptions:0];
        [dataDict setObject:@"binary" forKey:@"@type"];
        [dataDict setObject:base64Encoded forKey:@"base64"];
    }
    
    return dataDict;
}

+ (NSData *_Nonnull)base64DictToData:(NSDictionary *_Nullable)base64Dict
{
    if([@"binary" isEqualToString:base64Dict[@"@type"]]){
        NSString *base64 = base64Dict[@"base64"];
        NSData *sendData = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
        return sendData;
    }
    return nil;
}

+ (long) getUnixFixTimeMillis
{
    static long sInterval;
    static dispatch_once_t unixTimeToken;
    
    dispatch_once(&unixTimeToken, ^{
        sInterval = [[NSDate date] timeIntervalSince1970] * 1000 - CACurrentMediaTime()*1000;
    });
    return sInterval+CACurrentMediaTime()*1000;
}

+ (NSArray<NSString *> *)extractPropertyNamesOfJSValueObject:(JSValue *)jsvalue
{
    if (!jsvalue) {
        return nil;
    }
    
    NSMutableArray* allKeys = nil;
    
    if ([self useJSCApiForCreateInstance]) {
        JSContextRef contextRef = jsvalue.context.JSGlobalContextRef;
        if (![jsvalue isObject]) {
            WXAssert(NO, @"Invalid jsvalue for property enumeration.");
            return nil;
        }
        JSValueRef jsException = NULL;
        JSObjectRef instanceContextObjectRef = JSValueToObject(contextRef, jsvalue.JSValueRef, &jsException);
        if (jsException != NULL) {
            WXLogError(@"JSValueToObject Exception during create instance.");
        }
        BOOL somethingWrong = NO;
        if (instanceContextObjectRef != NULL) {
            JSPropertyNameArrayRef allKeyRefs = JSObjectCopyPropertyNames(contextRef, instanceContextObjectRef);
            size_t keyCount = JSPropertyNameArrayGetCount(allKeyRefs);
            
            allKeys = [[NSMutableArray alloc] initWithCapacity:keyCount];
            for (size_t i = 0; i < keyCount; i ++) {
                JSStringRef nameRef = JSPropertyNameArrayGetNameAtIndex(allKeyRefs, i);
                size_t len = JSStringGetMaximumUTF8CStringSize(nameRef);
                if (len > 1024) {
                    somethingWrong = YES;
                    break;
                }
                char* buf = (char*)malloc(len + 5);
                if (buf == NULL) {
                    somethingWrong = YES;
                    break;
                }
                bzero(buf, len + 5);
                if (JSStringGetUTF8CString(nameRef, buf, len + 5) > 0) {
                    NSString* keyString = [NSString stringWithUTF8String:buf];
                    if ([keyString length] == 0) {
                        somethingWrong = YES;
                        free(buf);
                        break;
                    }
                    [allKeys addObject:keyString];
                }
                else {
                    somethingWrong = YES;
                    free(buf);
                    break;
                }
                free(buf);
            }
            JSPropertyNameArrayRelease(allKeyRefs);
        } else {
            somethingWrong = YES;
        }
        
        if (somethingWrong) {
            // may contain retain-cycle.
            allKeys = (NSMutableArray*)[[jsvalue toDictionary] allKeys];
        }
    }
    else {
        allKeys = (NSMutableArray*)[[jsvalue toDictionary] allKeys];
    }
    
    return allKeys;
}

@end


//Deprecated
CGFloat WXScreenResizeRadio(void)
{
    return [WXUtility defaultPixelScaleFactor];
}

CGFloat WXPixelResize(CGFloat value)
{
    return WXCeilPixelValue(value * WXScreenResizeRadio());
}

CGRect WXPixelFrameResize(CGRect value)
{
    CGRect new = CGRectMake(value.origin.x * WXScreenResizeRadio(),
                            value.origin.y * WXScreenResizeRadio(),
                            value.size.width * WXScreenResizeRadio(),
                            value.size.height * WXScreenResizeRadio());
    return new;
}

CGPoint WXPixelPointResize(CGPoint value)
{
    CGPoint new = CGPointMake(value.x * WXScreenResizeRadio(),
                              value.y * WXScreenResizeRadio());
    return new;
}

