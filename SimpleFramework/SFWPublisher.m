
/*
The MIT License

Copyright (c) 2015 Jose Rojas, Redline Solutions, LLC.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

#import <objc/runtime.h>
#import "SFWWeakRef.h"
#import "SFWTaskQueue.h"
#import "SFWPublisher.h"

@interface SFWPublisherProxy : NSObject

@property NSMutableArray * observers;
@property NSMutableDictionary * selectorToSignature;

@end

@implementation SFWPublisherProxy

- (instancetype)initWithProtocol: (Protocol*) proto {
    self.observers = [NSMutableArray new];
    self.selectorToSignature = [NSMutableDictionary new];

    [self addProtocol:proto methods:YES];
    [self addProtocol:proto methods:NO];

    return self;
}

- (void) addProtocol: (Protocol *) proto methods: (BOOL) req {
    unsigned int count = 0;
    struct objc_method_description* list = protocol_copyMethodDescriptionList(proto, req, YES, &count);

    int i = 0;
    while (i < count)  {
        struct objc_method_description method = list[i];
        NSMethodSignature * theMethodSignature = [NSMethodSignature signatureWithObjCTypes:method.types];

        SEL sel = method.name;
        self.selectorToSignature[NSStringFromSelector(sel)] = @{
                @"signature" : theMethodSignature,
                @"required": @(req && sel != nil)
        };

        i++;
    }

    free(list);
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {

    NSDictionary* dict = self.selectorToSignature[NSStringFromSelector(anInvocation.selector)];
    BOOL isRequired = ((NSNumber *)dict[@"required"]).boolValue;

    @synchronized (self) {
        NSArray *observers = [NSArray arrayWithArray:self.observers];
        for (SFWWeakRef *observer in observers) {
            if (isRequired || [observer.value respondsToSelector:anInvocation.selector])
                [anInvocation invokeWithTarget:observer.value];
        }
    }
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    NSDictionary* dict = self.selectorToSignature[NSStringFromSelector(aSelector)];
    return dict[@"signature"];
}

- (void) addObserver: (id)observer {
    @synchronized (self) {
        NSArray *observers = [NSArray arrayWithArray:
            [self.observers filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"value = nil"]]
        ];
        [self.observers removeObjectsInArray:observers];
        id objectToAdd = [SFWWeakRef weakRef:observer];
        if (![self.observers containsObject:objectToAdd])
            [self.observers addObject:objectToAdd];
    }
}

- (void) removeObserver: (id)observer {
    @synchronized (self) {
        [self.observers removeObject:[SFWWeakRef weakRef:observer]];
    }
}

@end


void SFWPublisherSubscribe(id<SFWPublisher> self, id observer) {

    if ([self respondsToSelector:@selector(subscribeKeys)]) {
        NSArray * protocols = [self subscribeKeys];

        for (Protocol* proto in protocols) {
            BOOL subscribe = YES;
            if ([self respondsToSelector:@selector(onSubscribe:key:)])
                subscribe = [self onSubscribe:observer key:proto];
            if ([observer conformsToProtocol:proto] && subscribe) {
                SFWPublisherProxy * surrogate = SFWPublisherWithProtocol(self, proto);

                [surrogate addObserver:observer];
            }
        }
    }

}

void SFWPublisherUnsubscribe(id<SFWPublisher> self, id observer) {

    if ([self respondsToSelector:@selector(subscribeKeys)]) {
        NSArray * protocols = [self subscribeKeys];

        for (Protocol* proto in protocols) {
            BOOL unsubscribe = YES;
            if ([self respondsToSelector:@selector(onUnsubscribe:key:)])
                unsubscribe = [self onUnsubscribe:observer key:proto];
            if ([observer conformsToProtocol:proto] && unsubscribe) {
                SFWPublisherProxy * surrogate = SFWPublisherWithProtocol(self, proto);

                [surrogate removeObserver:observer];
            }
        }
    }

}

static const char* NSOBJECT_SFWPUBLISHER_DICT_KEY = "SFWPublisher_dict_key";

id SFWPublisherWithProtocol(id<SFWPublisher> self, Protocol* proto) {
    NSMutableDictionary * dict = objc_getAssociatedObject(self, NSOBJECT_SFWPUBLISHER_DICT_KEY);

    if (dict == nil) {
        dict = [NSMutableDictionary new];
        objc_setAssociatedObject(self, NSOBJECT_SFWPUBLISHER_DICT_KEY, dict, OBJC_ASSOCIATION_RETAIN);
    }

    NSString* key = NSStringFromProtocol(proto);
    SFWPublisherProxy * surrogate = dict[key];
    if (surrogate == nil) {
        dict[key] = surrogate = [[SFWPublisherProxy alloc] initWithProtocol:proto];
    }

    return surrogate;
}

void SFWPublisherPublishToObserversUsingProtocol(id<SFWPublisher> self, Protocol* proto, SFWPublisherBlock_t block) {
    SFWPublisherPublishToObserversUsingProtocolAndQueue(self, proto, nil, block);
}

void SFWPublisherPublishToObserversUsingProtocolAndQueue(id<SFWPublisher> self, Protocol* proto, SFWTaskQueue * queue, SFWPublisherBlock_t block) {

    SFWPublisherProxy * publisher = SFWPublisherWithProtocol(self, proto);

    if (queue == nil)
        block(publisher);
    else
        [queue queueAsync:^{
            block(publisher);
        }];

}

@implementation SFWPublisher

- (void)subscribeObserver:(id)observer {
    SFWPublisherSubscribe(self, observer);
}

- (void)unsubscribeObserver:(id)observer {
    SFWPublisherUnsubscribe(self, observer);
}

- (BOOL)onSubscribe:(id)observer key:(Protocol *)proto {
    return YES;
}

- (BOOL)onUnsubscribe:(id)observer key:(Protocol *)proto {
    return YES;
}

- (NSArray *)subscribeKeys {
    return nil;
}

- (id) publisherForObserversUsing: (Protocol *) proto {
    return SFWPublisherWithProtocol(self, proto);
}

- (void) publishToObserversUsing: (Protocol *) proto block: (SFWPublisherBlock_t) block {
    SFWPublisherPublishToObserversUsingProtocol(self, proto, block);
}

- (void) publishToObserversUsing: (Protocol *) proto queue: (SFWTaskQueue *) queue block: (SFWPublisherBlock_t) block {
    SFWPublisherPublishToObserversUsingProtocolAndQueue(self, proto, queue, block);
}


@end

@implementation SFWTypedPublisher

- (id) typedPublisherForObserversUsing: (Protocol *) proto {
    return [self publisherForObserversUsing:proto];
}

@end
