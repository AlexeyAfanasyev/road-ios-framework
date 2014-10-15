//
//  RFWebServiceCachingManager.m
//  ROADWebService
//
//  Copyright (c) 2014 EPAM Systems, Inc. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  Redistributions of source code must retain the above copyright notice, this
//  list of conditions and the following disclaimer.
//  Redistributions in binary form must reproduce the above copyright notice, this
//  list of conditions and the following disclaimer in the documentation and/or
//  other materials provided with the distribution.
//  Neither the name of the EPAM Systems, Inc.  nor the names of its contributors
//  may be used to endorse or promote products derived from this software without
//  specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//  See the NOTICE file and the LICENSE file distributed with this work
//  for additional information regarding copyright ownership and licensing


#import "RFWebServiceCachingManager.h"
#import <CoreData/CoreData.h>
#import <ROAD/ROADCore.h>

#import "RFWebServiceLog.h"
#import "RFWebResponse.h"
#import "RFWebServiceCacheContext.h"
#import "RFWebServiceCache.h"


NSString * const kRFCacheTemplateEscapeString = @"%%";

static NSString * const kRFWebResponseEntityName = @"WebResponse";

const char * RFWebServiceCacheQueueName = "RFWebServiceCacheQueue";


@implementation RFWebServiceCachingManager {
    RFWebServiceCacheContext * _cacheContext;
}


#pragma mark - Initialization

- (id)init {
    self = [super init];
    if (self) {
        _cacheContext = [[RFWebServiceCacheContext alloc] init];
    }
    return self;
}


#pragma mark - RFWebServiceCachingManaging

- (void)setCacheWithRequest:(NSURLRequest *)request response:(NSHTTPURLResponse *)response responseBodyData:(NSData *)responseBodyData expirationDate:(NSDate *)expirationDate cacheIdentifier:(NSString *)cacheIdentifier {
    if (!expirationDate) {
        expirationDate = [RFWebServiceCachingManager expirationDateFromResponse:response];
    }

    NSString *lastModified = [RFWebServiceCachingManager lastModifiedFromResponse:response];
    NSString *eTag = [RFWebServiceCachingManager eTagFromResponse:response];

    // Either we have expiration date specified or expiration date is not specified but we have field for conditional GET
    if ([expirationDate compare:[NSDate date]] == NSOrderedDescending
        || ((lastModified || eTag) && !expirationDate)) {
        [_cacheContext.context performBlockAndWait:^{
            NSManagedObjectContext *managedObjectContext = self->_cacheContext.context;

            RFWebResponse * webResponse = [self unsafeFetchResponseForRequest:request];
            if (!webResponse) {
                webResponse = [NSEntityDescription insertNewObjectForEntityForName:kRFWebResponseEntityName inManagedObjectContext:managedObjectContext];
                webResponse.urlHash = [[NSDecimalNumber alloc] initWithUnsignedInteger:[[request.URL absoluteString] hash]];
                webResponse.cacheIdentifier = cacheIdentifier;
                webResponse.implementation.requestURL = [request.URL absoluteString];
            }

            webResponse.implementation.requestBodyData = request.HTTPBody;
            webResponse.implementation.response = [NSKeyedArchiver archivedDataWithRootObject:response];
            webResponse.implementation.responseBodyData = responseBodyData;
            webResponse.implementation.expirationDate = expirationDate;
            webResponse.implementation.eTag = eTag;
            webResponse.implementation.lastModified = lastModified;
            
            // Remove old one if exist
            if ([cacheIdentifier length]) {
                NSArray *responsesWithCacheId = [self unsafeFetchResponseForIdentifier:cacheIdentifier prefixed:NO];
                for (RFWebResponse *cachedResponse in responsesWithCacheId) {
                    if (cachedResponse.objectID != webResponse.objectID) {
                        [managedObjectContext deleteObject:cachedResponse];
                    }
                }
            }

            
            NSError *error;
            [managedObjectContext save:&error];
            
            if (error) {
                RFWSLogError(@"RFWebServiceCachingManager error: saving cached response failed with error: %@", [error localizedDescription]);
            }
        }];
    }
}

- (void)setCacheWithRequest:(NSURLRequest *)request response:(NSHTTPURLResponse *)response responseBodyData:(NSData *)responseBodyData expirationDate:(NSDate *)expirationDate {
    [self setCacheWithRequest:request response:response responseBodyData:responseBodyData expirationDate:expirationDate cacheIdentifier:@""];
}

- (RFWebResponse *)cacheWithRequest:(NSMutableURLRequest *)request {
    RFWebResponse *cachedResponse = [self fetchResponseForRequest:request];
    if (!cachedResponse.implementation.expirationDate
        || [cachedResponse.implementation.expirationDate compare:[NSDate date]] == NSOrderedAscending) {

        // If ETag or Last-Modified then we should ask server for updates
        if (cachedResponse.implementation.eTag || cachedResponse.implementation.lastModified) {
            [RFWebServiceCachingManager addCacheHeadersToRequest:request fromCachedResponse:cachedResponse];
        }

        cachedResponse = nil;
    }

    return cachedResponse;
}

- (RFWebResponse *)cacheForResponse:(NSHTTPURLResponse *)response request:(NSURLRequest *)request cacheAttribute:(RFWebServiceCache *)cacheAttribute {
    RFWebResponse *cachedResponse = [self fetchResponseForRequest:request];
    
    if (!(cacheAttribute.offlineCache && !response) && [response statusCode] != 304) {
        if (cachedResponse) {
            [_cacheContext.context performBlockAndWait:^{
                [self->_cacheContext.context deleteObject:cachedResponse];
                NSError *saveError;
                [self->_cacheContext.context save:&saveError];
                if (saveError) {
                    RFWSLogError(@"Clean of cache was failed with error : %@", saveError);
                }
            }];
        }
        cachedResponse = nil;
    }

    return cachedResponse;
}

- (NSArray *)cacheWithIdentifier:(NSString *)cacheIdentifier {
    __block NSArray *cachedResponse;

    [_cacheContext.context performBlockAndWait:^{
        cachedResponse = [self unsafeFetchResponseForIdentifier:cacheIdentifier prefixed:NO];
    }];

    return cachedResponse;
}

- (NSArray *)cacheWithIdentifierPrefix:(NSString *)cacheIdentifierPrefix {
    __block NSArray *cachedResponse;

    [_cacheContext.context performBlockAndWait:^{
        cachedResponse = [self unsafeFetchResponseForIdentifier:cacheIdentifierPrefix prefixed:YES];
    }];

    return cachedResponse;
}

- (void)flushElementsWithIdentifier:(NSString *)cacheIdentifier {
    NSArray *cachedResponses = [self cacheWithIdentifier:cacheIdentifier];

    [_cacheContext.context performBlockAndWait:^{
        for (RFWebResponse *cachedResponse in cachedResponses) {
            [self->_cacheContext.context deleteObject:cachedResponse];
            NSError *error;
            [self->_cacheContext.context save:&error];
            if (error) {
                RFWSLogError(@"Clean of cache was failed with error : %@", error);
            }
        }
    }];
}

- (void)flushElementsWithIdentifierPrefix:(NSString *)cacheIdentifierPrefix {
    NSArray *cachedResponses = [self cacheWithIdentifierPrefix:cacheIdentifierPrefix];
    
    [_cacheContext.context performBlockAndWait:^{
        for (RFWebResponse *cachedResponse in cachedResponses) {
            [self->_cacheContext.context deleteObject:cachedResponse];
            NSError *error;
            [self->_cacheContext.context save:&error];
            if (error) {
                RFWSLogError(@"Clean of cache was failed with error : %@", error);
            }
        }
    }];
}

- (void)dropCache {
    
    [_cacheContext.context performBlockAndWait:^{
        NSError *error;
        [self->_cacheContext.persisitentStoreCoordinator removePersistentStore:[self->_cacheContext.persisitentStoreCoordinator.persistentStores lastObject] error:&error];
        if (error) {
            RFWSLogError(@"Cache failed to be dropped with error : %@", error);
        }
        else {
            if ([[NSFileManager defaultManager] fileExistsAtPath:[[self->_cacheContext.storeURL absoluteString] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]) {
                [[NSFileManager defaultManager] removeItemAtURL:self->_cacheContext.storeURL error:&error];
                if (error) {
                    RFWSLogError(@"Cache file failed to be dropped with error : %@", error);
                }
                else {
                    [self->_cacheContext bindStore];
                }
            }
            else {
                [self->_cacheContext bindStore];
            }
        }
    }];
}

- (NSString *)parseCacheIdentifier:(NSString *)cacheIdentifier withParameters:(NSDictionary *)parameterValues {
    NSMutableString *parsingCacheIdentifier = [[NSMutableString alloc] init];
    if (cacheIdentifier) {
        [parsingCacheIdentifier appendString:cacheIdentifier];
    }
    [parsingCacheIdentifier RF_formatUsingValues:parameterValues withEscape:kRFCacheTemplateEscapeString];
    return [NSString stringWithString:parsingCacheIdentifier];
}

#pragma mark - Utility methods

static NSString * const kRFWebServiceHeaderFieldPragma              = @"Pragma";
static NSString * const kRFWebServiceHeaderFieldCacheControl        = @"Cache-Control";
static NSString * const kRFWebServiceHeaderFieldExpires             = @"Expires";
static NSString * const kRFWebServiceHeaderFieldETag                = @"ETag";
static NSString * const kRFWebServiceHeaderFieldLastModified        = @"Last-Modified";
static NSString * const kRFWebServiceHeaderFieldIfModifiedSince     = @"If-Modified-Since";
static NSString * const kRFWebServiceHeaderFieldIfNoneMatch         = @"If-None-Match";
static NSString * const kRFWebServiceHeaderNoCacheValue             = @"no-cache";
static NSString * const kRFWebServiceHeaderMaxAgeKey                = @"max-age";
static NSString * const kRFWebServiceHeaderExpiresFormat            = @"EEE, dd MMM yyyy HH:mm:ss zzz";
static NSString * const kRFWebServiceHeaderParameterSeparator       = @",";
static NSString * const kRFWebServiceHeaderKeyValueSeparator        = @"=";
static const NSInteger kRFWebServiceHeaderValueParameterIndex       = 1;

+ (NSDate *)expirationDateFromResponse:(NSHTTPURLResponse *)response {
    NSDate *expirationDate;
    BOOL noCaching = NO;

    NSString *pragma = [response.allHeaderFields valueForKey:kRFWebServiceHeaderFieldPragma];
    if (pragma && [pragma rangeOfString:kRFWebServiceHeaderNoCacheValue].location != NSNotFound) {
        noCaching = YES;
    }

    if (!noCaching) {
        NSString *cacheControl = [response.allHeaderFields valueForKey:kRFWebServiceHeaderFieldCacheControl];
        NSArray *cacheControlComponents = [cacheControl componentsSeparatedByString:kRFWebServiceHeaderParameterSeparator];

        for (NSString *component in cacheControlComponents) {
            if ([component rangeOfString:kRFWebServiceHeaderNoCacheValue].location != NSNotFound) {
                expirationDate = nil;
                noCaching = YES;
                break;
            }

            if ([component rangeOfString:kRFWebServiceHeaderMaxAgeKey].location != NSNotFound) {
                NSArray *maxAgeComponents = [component componentsSeparatedByString:kRFWebServiceHeaderKeyValueSeparator];
                NSString *maxAgeValue = maxAgeComponents[kRFWebServiceHeaderValueParameterIndex];
                NSInteger maxAge = [maxAgeValue integerValue];
                expirationDate = [NSDate dateWithTimeIntervalSinceNow:maxAge];
            }
        }

        if (!expirationDate && !noCaching) {
            NSString *expires = [response.allHeaderFields valueForKey:kRFWebServiceHeaderFieldExpires];
            NSDateFormatter *expiresDateFormatter = [[NSDateFormatter alloc] init];
            expiresDateFormatter.dateFormat = kRFWebServiceHeaderExpiresFormat;
            expirationDate = [expiresDateFormatter dateFromString:expires];
        }
    }

    return expirationDate;
}

+ (NSString *)eTagFromResponse:(NSHTTPURLResponse *)response {
    return [response.allHeaderFields valueForKey:kRFWebServiceHeaderFieldETag];
}

+ (NSString *)lastModifiedFromResponse:(NSHTTPURLResponse *)response {
    return [response.allHeaderFields valueForKey:kRFWebServiceHeaderFieldLastModified];
}

+ (void)addCacheHeadersToRequest:(NSMutableURLRequest *)request fromCachedResponse:(RFWebResponse *)cachedResponse {
    if (cachedResponse.implementation.eTag) {
        [((NSMutableURLRequest *)request) setAllHTTPHeaderFields:[RFWebServiceCachingManager dictionary:[request allHTTPHeaderFields] setObject:cachedResponse.implementation.eTag forKey:kRFWebServiceHeaderFieldIfNoneMatch]];
    }

    if (cachedResponse.implementation.lastModified) {
        [((NSMutableURLRequest *)request) setAllHTTPHeaderFields:[RFWebServiceCachingManager dictionary:[request allHTTPHeaderFields] setObject:cachedResponse.implementation.lastModified forKey:kRFWebServiceHeaderFieldIfModifiedSince]];
    }
}

+ (NSDictionary *)dictionary:(NSDictionary *)dictionary setObject:(id)object forKey:(id<NSCopying>)key {
    NSMutableDictionary *newHeaders = [[NSMutableDictionary alloc] initWithCapacity:[dictionary count] + 1];
    newHeaders[key] = object;
    [newHeaders addEntriesFromDictionary:dictionary];
    return newHeaders;
}

- (RFWebResponse *)fetchResponseForRequest:(NSURLRequest *)request {
    __block RFWebResponse *cachedResponse;
    [_cacheContext.context performBlockAndWait:^{
        cachedResponse = [self unsafeFetchResponseForRequest:request];
    }];

    return cachedResponse;
}

// This method should be called only with private queue of _cacheContext.context.
- (RFWebResponse *)unsafeFetchResponseForRequest:(NSURLRequest *)request {
    RFWebResponse *cachedResponse;

    NSUInteger requestURLHash = [[request.URL absoluteString] hash];

    NSFetchRequest *fetchCachedResponse = [[NSFetchRequest alloc] initWithEntityName:kRFWebResponseEntityName];
    fetchCachedResponse.predicate = [NSPredicate predicateWithFormat:@"urlHash == %lu", requestURLHash];
    NSError *error;
    NSArray *cachedResponses = [_cacheContext.context executeFetchRequest:fetchCachedResponse error:&error];

    for (RFWebResponse *webResponse in cachedResponses) {
        if ([webResponse.implementation.requestURL isEqualToString:[request.URL absoluteString]]
            && ((request.HTTPBody.length == 0 && webResponse.implementation.requestBodyData.length == 0)
                || [webResponse.implementation.requestBodyData isEqualToData:request.HTTPBody])) {
                cachedResponse = webResponse;
                break;
            }
    }

    return cachedResponse;
}

// This method should be called only with private queue of _cacheContext.context.
- (NSArray *)unsafeFetchResponseForIdentifier:(NSString *)cacheIdentifier prefixed:(BOOL)prefixed {

    NSMutableArray *cachedResponse = [[NSMutableArray alloc] init];

    NSFetchRequest *fetchCachedResponse = [[NSFetchRequest alloc] initWithEntityName:kRFWebResponseEntityName];

    if (prefixed) {
        fetchCachedResponse.predicate = [NSPredicate predicateWithFormat:@"cacheIdentifier BEGINSWITH[cd] %@", cacheIdentifier];
    }
    else {
        fetchCachedResponse.predicate = [NSPredicate predicateWithFormat:@"cacheIdentifier == %@", cacheIdentifier];
    }

    NSError *executeError;
    NSArray *cachedResponses = [_cacheContext.context executeFetchRequest:fetchCachedResponse error:&executeError];

    for (RFWebResponse *webResponse in cachedResponses) {
        if ([webResponse.implementation.expirationDate compare:[NSDate date]] == NSOrderedAscending) {
            [_cacheContext.context deleteObject:webResponse];
            NSError *error;
            [_cacheContext.context save:&error];
            if (error) {
                RFWSLogError(@"Clean of cache was failed with error : %@", error);
            }
        } else {
            [cachedResponse addObject:webResponse];
        }
    }
    
    return [NSArray arrayWithArray:cachedResponse];
}


@end
