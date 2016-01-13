[By Andras, 21st January 2012](http://codeshaker.blogspot.com.br/2012/01/aop-delivered.html)


AOP. Delivered.
--------------


After several attempts at making an aspect oriented solution in Objective C, I think I finally figured out an acceptable and reliable solution. The goal was to find a way to intercept any message call without the need of wrapping any object through a Proxy. With the help of the objc runtime and the default message forwarding mechanisms, finally I could make it work. And the best part of it, is that in the end I made it without messing with type encodings, variable arguments, the various return types and functions, and without the need of calling implementations by hand. I had to use only a little low level stuff.

The base idea was to make a hook into the message sending mechanism and force it to the message forwarding route. Using the message forwarding we can take the advantage of high level NSInvocations that are automatically made by the runtime. The whole solution (at least in this first version) consists of only two classes, a wrapper class for holding information about the method we will intercept: AOPMethod, and the class that actually makes the whole thing from registration to catching messages: AOPAspect.

So a brief explanation about how it works:

1. At registration of a method call of a specific class it creates a method wrapper (AOPMethod) object and stores every information in it about that specific method along with the block that will be used upon interception.

2. Changes the implementation of the method to _objc_msgForward or _objc_msgForward_stret respectively using method_setImplementation. This is the point where we route message sending to the forwarding mechanism. The next time the message is called on the base class, it will return the _objc_msgForward implementation as if it not found the implementation. So it starts to resolve it by going through the message forwarding steps. Nice.

3. We add the forwardingTargetForSelector: method to the base class using class_addMethod to point to our implementation in the AOPAspect class. Also we add the original method implementation and selector (with an extended name to prevent conflicts between classes) to our AOPAspect instance.

4. In the forwardingTargetForSelector: method we give back our AOPAspect instance. With this we route the message forwarding from the base object to our AOPAspect object.

5. This forwardingTargetForSelector: method will be called again on AOPAspect as we don't have that selector implemented. This case we return nil, so message forwarding steps further and will check for the methodSignatureForSelector: and forwardInvocation: methods on AOPAspect.

6. In methodSignatureForSelector: we gave back the correct message signature that is already stored in a dictionary in a method wrapper object.

7. At the time it arrives to our implementation of forwardInvocation: in AOPAspect we have a fully configured NSInvocation instance and the only thing we have to do is to change the selector to the extended version we added to AOPAspect class. Here we can run the blocks registered for the given method before/after or even instead of the method call. And of course we can run the original method by calling [anInvocation invoke].

8. For simplicity, we just pass the NSInvocation object to the blocks registered for the method, so they can access all arguments and the return value as well through the getArgument:atIndex: and getReturnValue: methods.

And that's it. It works with all kind of return types, argument types and any variation of arguments.

So here are the classes.

```
#import "AOPAspect.h"
#import <objc/runtime.h>

@interface AOPMethod : NSObject

@property (assign, nonatomic) SEL selector;
@property (assign, nonatomic) IMP implementation;
@property (assign, nonatomic) Method method;
@property (assign, nonatomic) const char *typeEncoding;
@property (strong, nonatomic) NSMethodSignature *methodSignature;
@property (assign, nonatomic) BOOL hasReturnValue;
@property (assign, nonatomic) NSUInteger returnValueLength;

@property (copy, nonatomic) aspect_block_t beforeBlock;
@property (copy, nonatomic) aspect_block_t afterBlock;
@property (copy, nonatomic) aspect_block_t insteadBlock;

@end
```

```
#import "AOPMethod.h"

@implementation AOPMethod

@synthesize selector;
@synthesize implementation;
@synthesize method;
@synthesize typeEncoding;
@synthesize methodSignature;
@synthesize hasReturnValue;
@synthesize returnValueLength;

@synthesize beforeBlock;
@synthesize afterBlock;
@synthesize insteadBlock;

@end
```


and the essence of all:

```
typedef void (^aspect_block_t)(NSInvocation *invocation);

@interface AOPAspect : NSObject

- (void)interceptClass:(Class)aClass beforeExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block;
- (void)interceptClass:(Class)aClass afterExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block;
- (void)interceptClass:(Class)aClass insteadExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block;

+ (AOPAspect *)instance;

@end
```

```
#import "AOPAspect.h"
#import "AOPMethod.h"
#import <objc/runtime.h>
#import <objc/message.h>


#pragma mark - Type definitions


typedef enum {
    AOPAspectInspectorTypeBefore,
    AOPAspectInspectorTypeAfter,
    AOPAspectInspectorTypeInstead,
}AOPAspectInspectorType;


#pragma mark - Shared instance


static AOPAspect *aspectManager = NULL;
static Class currentClass;


#pragma mark - Implementation


@implementation AOPAspect {
    NSMutableDictionary *originalMethods;
    AOPMethod *forwardingMethod;
}


#pragma mark - Object lifecycle


- (id)init {
    self = [super init];
    if (self) {
        originalMethods = [[NSMutableDictionary alloc] init];
        forwardingMethod = [[AOPMethod alloc] init];
        forwardingMethod.selector = @selector(forwardingTargetForSelector:);
        forwardingMethod.implementation = class_getMethodImplementation([self class], forwardingMethod.selector);
        forwardingMethod.method = class_getInstanceMethod([self class], forwardingMethod.selector);
        forwardingMethod.typeEncoding = method_getTypeEncoding(forwardingMethod.method);
    }
    return self;
}

+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        aspectManager = [[AOPAspect alloc] init];
    });
}

+ (AOPAspect *)instance {
    return aspectManager;
}


#pragma mark - Helper methods


- (AOPMethod *)methodForKey:(NSString *)key {
    return [originalMethods objectForKey:key];
}

- (NSString *)keyWithClass:(Class)aClass selector:(SEL)selector {
    return [NSString stringWithFormat:@"%@%@", NSStringFromClass(aClass), NSStringFromSelector(selector)];
}

- (SEL)extendedSelectorWithClass:(Class)aClass selector:(SEL)selector {
    return NSSelectorFromString([self keyWithClass:aClass selector:selector]);
}

- (NSMutableDictionary *)originalMethods {
    return originalMethods;
}


#pragma mark - Interceptor registration


- (void)registerClass:(Class)aClass withSelector:(SEL)selector at:(AOPAspectInspectorType)type usingBlock:(aspect_block_t)block {
    NSString *key = [self keyWithClass:aClass selector:selector];
    AOPMethod *method = [originalMethods objectForKey:key];
  
    // Exit point: already registered
    if (method) {
        return;
    }
  
    // Setup the new method
    NSMethodSignature *methodSignature = [aClass instanceMethodSignatureForSelector:selector];
  
    method = [[AOPMethod alloc] init];
    method.selector = selector;
    method.hasReturnValue = [methodSignature methodReturnLength] > 0;
    method.methodSignature = methodSignature;
    method.returnValueLength = [methodSignature methodReturnLength];
  
    // Instance method only for now...
    method.method = class_getInstanceMethod(aClass, selector);
  
    if (method.returnValueLength > sizeof(double)) {
        method.implementation = class_getMethodImplementation_stret(aClass, selector);
    }
    else {
        method.implementation = class_getMethodImplementation(aClass, selector);
    }
  
    switch (type) {
        case AOPAspectInspectorTypeBefore:
            method.beforeBlock = block;
            break;
        case AOPAspectInspectorTypeAfter:
            method.afterBlock = block;
            break;
        case AOPAspectInspectorTypeInstead:
            method.insteadBlock = block;
            break;
    }
  
    [originalMethods setObject:method forKey:key];
  
    IMP interceptor = NULL;
  
    // Check method return type
    if (method.hasReturnValue && method.returnValueLength > sizeof(double)) {
        interceptor = (IMP)_objc_msgForward_stret;
    }
    else {
        interceptor = (IMP)_objc_msgForward;
    }
  
    // Change implementation
    method_setImplementation(method.method, interceptor);
    // Initiate hook to self
    class_addMethod(aClass, forwardingMethod.selector, forwardingMethod.implementation, forwardingMethod.typeEncoding);
    // Add method to self
    class_addMethod([self class], [self extendedSelectorWithClass:aClass selector:selector], method.implementation, method.typeEncoding);
}

- (void)interceptClass:(Class)aClass beforeExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block {
    [self registerClass:aClass withSelector:selector at:AOPAspectInspectorTypeBefore usingBlock:block];
}

- (void)interceptClass:(Class)aClass afterExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block {
    [self registerClass:aClass withSelector:selector at:AOPAspectInspectorTypeAfter usingBlock:block];
}

- (void)interceptClass:(Class)aClass insteadExecutingSelector:(SEL)selector usingBlock:(aspect_block_t)block {
    [self registerClass:aClass withSelector:selector at:AOPAspectInspectorTypeInstead usingBlock:block];
}


#pragma mark - Hook


- (id)forwardingTargetForSelector:(SEL)aSelector {
    if (self == [AOPAspect instance]) {
        return nil;
    }
  
    currentClass = [self class];
    return [AOPAspect instance];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    return [(AOPMethod *)[[self originalMethods] objectForKey:NSStringFromSelector([self extendedSelectorWithClass:currentClass selector:aSelector])] methodSignature];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
  
    AOPMethod *method = [self methodForKey:NSStringFromSelector([self extendedSelectorWithClass:currentClass selector:anInvocation.selector])];
  
    [anInvocation setSelector:[self extendedSelectorWithClass:currentClass selector:anInvocation.selector]];
  
    if (method.beforeBlock) {
        method.beforeBlock(anInvocation);
    }
  
    if (method.insteadBlock) {
        method.insteadBlock(anInvocation);
    }
    else {
        [anInvocation invoke];
    }
  
    if (method.afterBlock) {
        method.afterBlock(anInvocation);
    }
}

@end
```

Much have been left out like deregistration, testing, error checking, making it thread safe, etc... but I think the implementation of these should make no problem. And as you may noticed currently only instance methods are supported, class methods are still an issue to be solved.

It is far from a complete AOP framework, but for a blog post I think this will do.
