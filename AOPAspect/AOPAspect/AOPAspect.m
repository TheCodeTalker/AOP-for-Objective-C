//
//  AOPAspect.m
//  AOPAspect
//
//  Created by Andras Koczka on 1/21/12.
//  Copyright (c) 2012 Andras Koczka
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is furnished
//  to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included
//  in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
//  FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
//  COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
//  IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
//  WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#import "AOPAspect.h"
#import <objc/runtime.h>
#import <objc/message.h>


#pragma mark - Type definitions and keys

typedef enum : int {
    AOPAspectInspectorTypeBefore,
    AOPAspectInspectorTypeInstead,
    AOPAspectInspectorTypeAfter,
} AOPAspectInspectorType;

static NSString *const AOPAspectCurrentObjectKey = @"AOPAspectCurrentObjectKey";


#pragma mark - Shared instance


static AOPAspect *aspectManager = NULL;


#pragma mark - Implementation


@implementation AOPAspect {
    
    // interceptorStorage (dict) -> interceptorTypes (dict) -> interceptors (array) -> interceptor (array) -> block
    NSMutableDictionary *interceptorStorage; // Ok, this is ugly
    
    aspect_block_t methodInvoker;
    dispatch_queue_t synchronizerQueue;
}


#pragma mark - Object lifecycle


+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        aspectManager = [[AOPAspect alloc] init];
        aspectManager->interceptorStorage = [[NSMutableDictionary alloc] init];
        
        // Create queue for synchronization
        aspectManager->synchronizerQueue = dispatch_queue_create("Synchronizer queue - AOPAspect", DISPATCH_QUEUE_SERIAL);

        // Store the default method invoker block
        aspectManager->methodInvoker = ^(NSInvocation *invocation) {
            // Invoke the original method
            [invocation invoke];
        };
    });
}

+ (AOPAspect *)instance {
    return aspectManager;
}


#if !OS_OBJECT_USE_OBJC || (defined(__has_feature) && !__has_feature(objc_arc))
- (void)dealloc {
    dispatch_release(synchronizerQueue);
}
#endif

#pragma mark - Helper methods


- (NSString *)keyWithClass:(Class)aClass selector:(SEL)selector {
    return [NSString stringWithFormat:@"%@__%@", NSStringFromClass(aClass), NSStringFromSelector(selector)];
}

- (SEL)extendedSelectorWithClass:(Class)aClass selector:(SEL)selector {
    return NSSelectorFromString([self keyWithClass:aClass selector:selector]);
}

// Stores the current class in the thread dictionary.
- (void)setCurrentObject:(id)anObject {
    [[[NSThread currentThread] threadDictionary] setObject:anObject forKey:AOPAspectCurrentObjectKey];
}

- (id)currentObject {
    return [[[NSThread currentThread] threadDictionary] objectForKey:AOPAspectCurrentObjectKey];
}

- (Class)currentClass {
    return [[[[NSThread currentThread] threadDictionary] objectForKey:AOPAspectCurrentObjectKey] class];
}

- (NSString *)identifierWithClass:(Class)aClass selector:(SEL)aSelector array:(NSArray *)array {
    return [NSString stringWithFormat:@"%@ | %@ | %p", NSStringFromClass(aClass), NSStringFromSelector(aSelector), array];
}

#pragma mark - Interceptor registration

- (BOOL)restoreOriginalMethodWithClass:(Class)aClass selector:(SEL)aSelector {

    Method method = class_getInstanceMethod(aClass, aSelector);
    IMP implementation;

    SEL extendedSelector = [self extendedSelectorWithClass:aClass selector:aSelector];
    
    IMP objcMsgForward;
    if ([[aClass instanceMethodSignatureForSelector:aSelector] methodReturnLength] > sizeof(double)) {
#ifndef __arm64__
        implementation = class_getMethodImplementation_stret([self class], extendedSelector);
        objcMsgForward = (IMP)_objc_msgForward_stret;
#else
        implementation = class_getMethodImplementation([self class], extendedSelector);
        objcMsgForward = (IMP)_objc_msgForward;
#endif
    }
    else {
        implementation = class_getMethodImplementation([self class], extendedSelector);
        objcMsgForward = (IMP)_objc_msgForward;
    }


    if (implementation && implementation != objcMsgForward) {
        method_setImplementation(method, implementation);
        return YES;
    }
    else {
        return NO;
    }
}

- (void)interceptMethodWithClass:(Class)aClass selector:(SEL)aSelector {
    
    Method method = class_getInstanceMethod(aClass, aSelector);
    IMP implementation;
    
    // Check method return type
    if ([[aClass instanceMethodSignatureForSelector:aSelector] methodReturnLength] > sizeof(double)) {
#ifndef __arm64__
        implementation = (IMP)_objc_msgForward_stret;
#else
        implementation = (IMP)_objc_msgForward;
#endif
    }
    else {
        implementation = (IMP)_objc_msgForward;
    }
    
    // Change the implementation
    method_setImplementation(method, implementation);
}

- (NSString *)storeInterceptorBlock:(aspect_block_t)block withClass:(Class)aClass selector:(SEL)aSelector type:(AOPAspectInspectorType)type {
    
    NSString *key = [self keyWithClass:aClass selector:aSelector];

    // Get the type dictionary
    NSMutableDictionary *interceptorTypeDictionary = [interceptorStorage objectForKey:key];
    
    // Create a type dictionary if needed
    if (!interceptorTypeDictionary) {
        interceptorTypeDictionary = [[NSMutableDictionary alloc] init];
        [interceptorStorage setObject:interceptorTypeDictionary forKey:key];
    }
    
    // Get the interceptors array
    NSMutableArray *interceptors = [interceptorTypeDictionary objectForKey:@(type)];
    
    // Initialize a new array (if needed) for storing interceptors. One array for each type: before, instead, after
    if (!interceptors) {
        interceptors = [[NSMutableArray alloc] init];
        [interceptorTypeDictionary setObject:interceptors forKey:@(type)];
    }
    
    // Wrap the interceptor into an NSDictionary so its address will be unique
    NSArray *interceptor = @[block];
    
    // Remove the default methodinvoker in case of a new "instead" type interceptor
    if (type == AOPAspectInspectorTypeInstead && interceptors.count == 1) {
        if ([[interceptors lastObject] lastObject] == (id)methodInvoker) {
            [interceptors removeLastObject];
        }
    }
    
    [interceptors addObject:interceptor];
    
    // Return a unique identifier that can be used to identify a certain interceptor
    return [self identifierWithClass:aClass selector:aSelector array:interceptor];
}

- (NSString *)registerClass:(Class)aClass withSelector:(SEL)aSelector type:(AOPAspectInspectorType)type usingBlock:(aspect_block_t)block {
    NSParameterAssert(aClass);
    NSParameterAssert(aSelector);
    NSParameterAssert(block);

    SEL extendedSelector = [self extendedSelectorWithClass:aClass selector:aSelector];
    
    // Hook a new method
    if (![self respondsToSelector:extendedSelector]) {
        
        // Get the instance method
        Method method = class_getInstanceMethod(aClass, aSelector);
        NSAssert(method, @"No instance method found for the given selector. Only instance methods can be intercepted.");
        
        IMP implementation;
        NSMethodSignature *methodSignature = [aClass instanceMethodSignatureForSelector:aSelector];
        
        // Get the original method implementation
        if ([methodSignature methodReturnLength] > sizeof(double)) {
#ifndef __arm64__
            implementation = class_getMethodImplementation_stret(aClass, aSelector);
#else
            implementation = class_getMethodImplementation(aClass, aSelector);
#endif
        }
        else {
            implementation = class_getMethodImplementation(aClass, aSelector);

            if (implementation) {
                if (class_addMethod(aClass, aSelector, implementation, method_getTypeEncoding(method))) {
                    implementation = class_getMethodImplementation(aClass, aSelector);
                }
            }
        }

        // Get the forwarding method properties
        SEL forwardingMethodSelector = @selector(forwardingTargetForSelector:);
        IMP forwardingMethodImplementation = class_getMethodImplementation([self class], @selector(baseClassForwardingTargetForSelector:));
        Method forwardingMethod = class_getInstanceMethod([self class], @selector(baseClassForwardingTargetForSelector:));
        const char *forwardingMethodTypeEncoding = method_getTypeEncoding(forwardingMethod);

        // Add the original forwarding method with the extended selector to self
        IMP originalForwardingMethodImp = class_getMethodImplementation(aClass, forwardingMethodSelector);
        SEL extendedForwardingSelector = [self extendedSelectorWithClass:aClass selector:forwardingMethodSelector];
        class_addMethod([self class], extendedForwardingSelector, originalForwardingMethodImp, forwardingMethodTypeEncoding);

        // Add the original method with the extended selector to self
        const char *typeEncoding = method_getTypeEncoding(method);
        class_addMethod([self class], extendedSelector, implementation, typeEncoding);

        // Initiate hook to self on the base object
        __unused IMP replacedImp = class_replaceMethod(aClass, forwardingMethodSelector, forwardingMethodImplementation, forwardingMethodTypeEncoding);

        [self interceptMethodWithClass:aClass selector:aSelector];

        // Add the default method invoker block
        dispatch_sync(synchronizerQueue, ^{
            [self storeInterceptorBlock:methodInvoker withClass:aClass selector:aSelector type:AOPAspectInspectorTypeInstead];
        });
    }
    
    // Store the interceptor block
    __block NSString *identifier;
    dispatch_sync(synchronizerQueue, ^{
        identifier = [self storeInterceptorBlock:block withClass:aClass selector:aSelector type:type];
    });
    
    return identifier;
}

- (NSString *)interceptClass:(Class)aClass beforeExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block {
    return [self registerClass:aClass withSelector:selector type:AOPAspectInspectorTypeBefore usingBlock:block];
}

- (NSString *)interceptClass:(Class)aClass afterExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block {
    return [self registerClass:aClass withSelector:selector type:AOPAspectInspectorTypeAfter usingBlock:block];
}

- (NSString *)interceptClass:(Class)aClass insteadExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block {
    return [self registerClass:aClass withSelector:selector type:AOPAspectInspectorTypeInstead usingBlock:block];
}

- (void)deregisterMethodWithClass:(Class)aClass selector:(SEL)aSelector {
    
    [self restoreOriginalMethodWithClass:aClass selector:aSelector];
    [interceptorStorage removeObjectForKey:[self keyWithClass:aClass selector:aSelector]];
}

- (void)removeInterceptorWithIdentifier:(NSString *)identifier {

    // Get the class and the selector from the identifier
    NSArray *components = [identifier componentsSeparatedByString:@" | "];
    Class aClass = NSClassFromString([components objectAtIndex:0]);
    SEL selector = NSSelectorFromString([components objectAtIndex:1]);
    
    dispatch_sync(synchronizerQueue, ^{
        
        // Search for the interceptor that belongs to the given identifier
        for (NSDictionary *interceptorTypeDictionary in [interceptorStorage allValues]) {
            NSInteger interceptorCount = 0;
            
            for (AOPAspectInspectorType i = AOPAspectInspectorTypeBefore; i <= AOPAspectInspectorTypeAfter; i++) {
                NSMutableArray *interceptors = [interceptorTypeDictionary objectForKey:@(i)];
                
                for (NSArray *array in [interceptors copy]) {
                    // If found remove the interceptor
                    if ([[self identifierWithClass:aClass selector:selector array:array] isEqualToString:identifier]) {
                        [interceptors removeObject:array];
                        
                        // Add back the default method invoker block in case of no more "instead" type blocks
                        if (i == AOPAspectInspectorTypeInstead && interceptors.count == 0) {
                            [self storeInterceptorBlock:methodInvoker withClass:aClass selector:selector type:i];
                        }
                    }
                }
                
                interceptorCount += interceptors.count;
            }
            
            // If only the default methodinvoker interceptor remained than deregister the method to improve performance
            if (interceptorCount == 1 && [[[interceptorTypeDictionary objectForKey:@(AOPAspectInspectorTypeInstead)] lastObject] lastObject] == (id)methodInvoker) {
                [self deregisterMethodWithClass:aClass selector:selector];
            }
        }
    });
}


#pragma mark - Hook


- (id)baseClassForwardingTargetForSelector:(SEL)aSelector {
    
    // In case the selector is not implemented on the base class
    if (![self respondsToSelector:aSelector]) {
        SEL extendedForwardingMethodSelector = [[AOPAspect instance] extendedSelectorWithClass:[self class] selector:@selector(forwardingTargetForSelector:)];

        // Invoke the original forwardingTargetForSelector method
        return ((id(*)(id, Method, SEL))method_invoke)([AOPAspect instance], class_getInstanceMethod([AOPAspect class], extendedForwardingMethodSelector), aSelector);
    }
    
    // Store the current class
    [[AOPAspect instance] setCurrentObject:self];
    
    return [AOPAspect instance];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    return [[self currentClass] instanceMethodSignatureForSelector:aSelector];
}

- (void)executeInterceptorsWithClass:(Class)aClass selector:(SEL)aSelector invocation:(NSInvocation *)anInvocation {
    
    NSString *key = [self keyWithClass:aClass selector:aSelector];
    __block NSMutableDictionary *interceptorTypeDictionary;
    
    dispatch_sync(synchronizerQueue, ^{
        interceptorTypeDictionary = [interceptorStorage objectForKey:key];
    });

    // Restore original state - this is needed for self and _cmd to be valid
    // FIXME: this could cause issues between threads
    {
        Class target = aClass;

        do {
            if (interceptorStorage[[self keyWithClass:target selector:aSelector]] != nil) {
                [aspectManager restoreOriginalMethodWithClass:target selector:aSelector];
            }

            target = class_getSuperclass(target);
        } while (target);
    }

    // Executes interceptors before, instead and after
    for (AOPAspectInspectorType aspectType = AOPAspectInspectorTypeBefore; aspectType <= AOPAspectInspectorTypeAfter; aspectType++) {
        __block NSArray *interceptors;

        dispatch_sync(synchronizerQueue, ^{
            interceptors = [[interceptorTypeDictionary objectForKey:@(aspectType)] copy];
        });

        for (NSArray *interceptor in interceptors) {
            aspect_block_t block = [interceptor lastObject];
            block(anInvocation);
        }
    }
    
    // Restore interception
    {
        Class target = aClass;

        do {
            if (interceptorStorage[[self keyWithClass:target selector:aSelector]] != nil) {
                [aspectManager interceptMethodWithClass:target selector:aSelector];
            }

            target = class_getSuperclass(target);
        } while (target);
    }
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {

    anInvocation.target = [self currentObject];
    [self executeInterceptorsWithClass:[self currentClass] selector:anInvocation.selector invocation:anInvocation];
}

@end
