// AFOAuth1Client.m
//
// Copyright (c) 2011 Mattt Thompson (http://mattt.me/)
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFOAuth1Client.h"
#import "AFHTTPRequestOperation.h"

#import <CommonCrypto/CommonHMAC.h>

static NSString * AFEncodeBase64WithData(NSData *data) {
    NSUInteger length = [data length];
    NSMutableData *mutableData = [NSMutableData dataWithLength:((length + 2) / 3) * 4];
    
    uint8_t *input = (uint8_t *)[data bytes];
    uint8_t *output = (uint8_t *)[mutableData mutableBytes];
    
    for (NSUInteger i = 0; i < length; i += 3) {
        NSUInteger value = 0;
        for (NSUInteger j = i; j < (i + 3); j++) {
            value <<= 8;
            if (j < length) {
                value |= (0xFF & input[j]);
            }
        }
        
        static uint8_t const kAFBase64EncodingTable[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        
        NSUInteger idx = (i / 3) * 4;
        output[idx + 0] = kAFBase64EncodingTable[(value >> 18) & 0x3F];
        output[idx + 1] = kAFBase64EncodingTable[(value >> 12) & 0x3F];
        output[idx + 2] = (i + 1) < length ? kAFBase64EncodingTable[(value >> 6)  & 0x3F] : '=';
        output[idx + 3] = (i + 2) < length ? kAFBase64EncodingTable[(value >> 0)  & 0x3F] : '=';
    }
    
    return [[NSString alloc] initWithData:mutableData encoding:NSASCIIStringEncoding];
}

static NSString * AFPercentEscapedQueryStringPairMemberFromStringWithEncoding(NSString *string, NSStringEncoding encoding) {
    static NSString * const kAFCharactersToBeEscaped = @":/?&=;+!@#$()~";
    static NSString * const kAFCharactersToLeaveUnescaped = @"[].";
    
	return (__bridge_transfer  NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (__bridge CFStringRef)string, (__bridge CFStringRef)kAFCharactersToLeaveUnescaped, (__bridge CFStringRef)kAFCharactersToBeEscaped, CFStringConvertNSStringEncodingToEncoding(encoding));
}

static NSDictionary * AFParametersFromQueryString(NSString *queryString) {
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    if (queryString) {
        NSScanner *parameterScanner = [[NSScanner alloc] initWithString:queryString];
        NSString *name = nil;
        NSString *value = nil;
        
        while (![parameterScanner isAtEnd]) {
            name = nil;        
            [parameterScanner scanUpToString:@"=" intoString:&name];
            [parameterScanner scanString:@"=" intoString:NULL];
            
            value = nil;
            [parameterScanner scanUpToString:@"&" intoString:&value];
            [parameterScanner scanString:@"&" intoString:NULL];		
            
            if (name && value) {
                [parameters setValue:[value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] forKey:[name stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
            }
        }
    }
    
    return parameters;
}

static inline BOOL AFQueryStringValueIsTrue(NSString *value) {
    return value && [[value lowercaseString] hasPrefix:@"t"];
}

@interface AFOAuth1Token ()
@property (readwrite, nonatomic, copy) NSString *key;
@property (readwrite, nonatomic, copy) NSString *secret;
@property (readwrite, nonatomic, copy) NSString *session;
@property (readwrite, nonatomic, copy) NSString *verifier;
@property (readwrite, nonatomic, strong) NSDate *expiration;
@property (readwrite, nonatomic, assign, getter = canBeRenewed) BOOL renewable;
@end

@implementation AFOAuth1Token
@synthesize key = _key;
@synthesize secret = _secret;
@synthesize session = _session;
@synthesize verifier = _verifier;
@synthesize expiration = _expiration;
@synthesize renewable = _renewable;
@dynamic expired;

- (id)initWithQueryString:(NSString *)queryString {
    self = [super init];
    if (!self) {
        return nil;
    }
    
    NSDictionary *attributes = AFParametersFromQueryString(queryString);
    
    self.key = attributes[@"oauth_token"];
    self.secret = attributes[@"oauth_token_secret"];
    self.session = attributes[@"oauth_session_handle"];
    
    if (attributes[@"oauth_token_duration"]) {
        self.expiration = [NSDate dateWithTimeIntervalSinceNow:[attributes[@"oauth_token_duration"] doubleValue]];
    }
    
    if (attributes[@"oauth_token_renewable"]) {
        self.renewable = AFQueryStringValueIsTrue(attributes[@"oauth_token_renewable"]);
    }
    
    return self;
}

@end

#pragma mark -

NSString * const kAFOAuth1Version = @"1.0";
NSString * const kAFApplicationLaunchedWithURLNotification = @"kAFApplicationLaunchedWithURLNotification";
#if __IPHONE_OS_VERSION_MIN_REQUIRED
NSString * const kAFApplicationLaunchOptionsURLKey = @"UIApplicationLaunchOptionsURLKey";
#else
NSString * const kAFApplicationLaunchOptionsURLKey = @"NSApplicationLaunchOptionsURLKey";
#endif

// TODO: the nonce is not path specific, so fix the signature:
static inline NSString * AFNounce() {
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    CFStringRef string = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return (NSString *)CFBridgingRelease(string);
}

static inline NSString * NSStringFromAFOAuthSignatureMethod(AFOAuthSignatureMethod signatureMethod) {
    switch (signatureMethod) {
        case AFHMACSHA1SignatureMethod:
            return @"HMAC-SHA1";
        case AFPlaintextSignatureMethod:
            return @"PLAINTEXT";
        default:
            return nil;
    }
}

static inline NSString * AFHMACSHA1SignatureWithConsumerSecretAndRequestTokenSecret(NSURLRequest *request, NSString *consumerSecret, NSString *requestTokenSecret, NSStringEncoding stringEncoding) {
    NSString* reqSecret = @"";
    if (requestTokenSecret != nil) {
        reqSecret = requestTokenSecret;
    }
    NSString *secretString = [NSString stringWithFormat:@"%@&%@", consumerSecret, reqSecret];
    NSData *secretStringData = [secretString dataUsingEncoding:stringEncoding];
    
    NSString *queryString = AFPercentEscapedQueryStringPairMemberFromStringWithEncoding([[[[[request URL] query] componentsSeparatedByString:@"&"] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] componentsJoinedByString:@"&"], stringEncoding);
    
    NSString *requestString = [NSString stringWithFormat:@"%@&%@&%@", [request HTTPMethod], AFPercentEscapedQueryStringPairMemberFromStringWithEncoding([[[request URL] absoluteString] componentsSeparatedByString:@"?"][0], stringEncoding), queryString];
    NSData *requestStringData = [requestString dataUsingEncoding:stringEncoding];
    
    // hmac
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CCHmacContext cx;
    CCHmacInit(&cx, kCCHmacAlgSHA1, [secretStringData bytes], [secretStringData length]);
    CCHmacUpdate(&cx, [requestStringData bytes], [requestStringData length]);
    CCHmacFinal(&cx, digest);
    
    // base 64
    NSData *data = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
    return AFEncodeBase64WithData(data);
}

static inline NSString * AFPlaintextSignatureWithConsumerSecretAndRequestTokenSecret(NSString *consumerSecret, NSString *requestTokenSecret, NSStringEncoding stringEncoding) {
    // TODO
    return nil;
}

static inline NSString * AFSignatureUsingMethodWithSignatureWithConsumerSecretAndRequestTokenSecret(NSURLRequest *request, AFOAuthSignatureMethod signatureMethod, NSString *consumerSecret, NSString *requestTokenSecret, NSStringEncoding stringEncoding) {
    switch (signatureMethod) {
        case AFHMACSHA1SignatureMethod:
            return AFHMACSHA1SignatureWithConsumerSecretAndRequestTokenSecret(request, consumerSecret, requestTokenSecret, stringEncoding);
        case AFPlaintextSignatureMethod:
            return AFPlaintextSignatureWithConsumerSecretAndRequestTokenSecret(consumerSecret, requestTokenSecret, stringEncoding);
        default:
            return nil;
    }
}


@interface NSURL (AFQueryExtraction)
- (NSString *)AF_getParamNamed:(NSString *)paramName;
@end

@implementation NSURL (AFQueryExtraction)

- (NSString *)AF_getParamNamed:(NSString *)paramName {
    NSString* query = [self query];
    
    NSScanner *scanner = [NSScanner scannerWithString:query];
    NSString *searchString = [[NSString alloc] initWithFormat:@"%@=",paramName];
    [scanner scanUpToString:searchString intoString:nil];
    // ToDo: check if this + [searchString length] works with all urlencoded params?
    NSUInteger startPos = [scanner scanLocation] + [searchString length];
    [scanner scanUpToString:@"&" intoString:nil];
    NSUInteger endPos = [scanner scanLocation];
    return [query substringWithRange:NSMakeRange(startPos, endPos - startPos)];
}

@end

@interface AFOAuth1Client ()
@property (readwrite, nonatomic, copy) NSString *key;
@property (readwrite, nonatomic, copy) NSString *secret;
@property (readwrite, nonatomic, copy) NSString *serviceProviderIdentifier;
@property (strong, readwrite, nonatomic) AFOAuth1Token *currentRequestToken;

- (void) signCallPerAuthHeaderWithPath:(NSString *)path 
                         andParameters:(NSDictionary *)parameters 
                             andMethod:(NSString *)method ;
- (NSDictionary *) signCallWithHttpGetWithPath:(NSString *)path 
                                 andParameters:(NSDictionary *)parameters 
                                     andMethod:(NSString *)method ;
@end

@implementation AFOAuth1Client
@synthesize key = _key;
@synthesize secret = _secret;
@synthesize serviceProviderIdentifier = _serviceProviderIdentifier;
@synthesize signatureMethod = _signatureMethod;
@synthesize realm = _realm;
@synthesize currentRequestToken = _currentRequestToken;
@synthesize accessToken = _accessToken;
@synthesize oauthAccessMethod = _oauthAccessMethod;

- (id)initWithBaseURL:(NSURL *)url
                  key:(NSString *)clientID
               secret:(NSString *)secret
{
    self = [super initWithBaseURL:url];
    if (!self) {
        return nil;
    }
    
    self.key = clientID;
    self.secret = secret;
    
    self.serviceProviderIdentifier = [self.baseURL host];
        
    self.oauthAccessMethod = @"GET";
    
    return self;
}


- (void)authorizeUsingOAuthWithRequestTokenPath:(NSString *)requestTokenPath
                          userAuthorizationPath:(NSString *)userAuthorizationPath
                                    callbackURL:(NSURL *)callbackURL
                                accessTokenPath:(NSString *)accessTokenPath
                                   accessMethod:(NSString *)accessMethod
                                        success:(void (^)(AFOAuth1Token *accessToken))success 
                                        failure:(void (^)(NSError *error))failure
{
    [self acquireOAuthRequestTokenWithPath:requestTokenPath callback:callbackURL accessMethod:(NSString *)accessMethod success:^(AFOAuth1Token *requestToken) {
        self.currentRequestToken = requestToken;
        [[NSNotificationCenter defaultCenter] addObserverForName:kAFApplicationLaunchedWithURLNotification object:nil queue:self.operationQueue usingBlock:^(NSNotification *notification) {
            
            NSURL *url = [[notification userInfo] valueForKey:kAFApplicationLaunchOptionsURLKey];
            
            self.currentRequestToken.verifier = [url AF_getParamNamed:@"oauth_verifier"];
                        
            [self acquireOAuthAccessTokenWithPath:accessTokenPath requestToken:self.currentRequestToken accessMethod:accessMethod success:^(AFOAuth1Token * accessToken) {
                if (success) {
                    success(accessToken);
                }
            } failure:^(NSError *error) {
                if (failure) {
                    failure(error);
                }
            }];
        }];
                
        NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
        [parameters setValue:requestToken.key forKey:@"oauth_token"];
#if __IPHONE_OS_VERSION_MIN_REQUIRED
        [[UIApplication sharedApplication] openURL:[[self requestWithMethod:@"GET" path:userAuthorizationPath parameters:parameters] URL]];
#else
        [[NSWorkspace sharedWorkspace] openURL:[[self requestWithMethod:@"GET" path:userAuthorizationPath parameters:parameters] URL]];
#endif
    } failure:failure];
}

- (void)acquireOAuthRequestTokenWithPath:(NSString *)path
                                callback:(NSURL *)callbackURL
                            accessMethod:(NSString *)accessMethod
                                 success:(void (^)(AFOAuth1Token *requestToken))success 
                                 failure:(void (^)(NSError *error))failure
{
    [self clearAuthorizationHeader];
    
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    [parameters setValue:self.key forKey:@"oauth_consumer_key"];
    
    if (self.realm) {
        [parameters setValue:self.realm forKey:@"realm"];
    }
    
    [parameters setValue:AFNounce() forKey:@"oauth_nonce"];
    [parameters setValue:[[NSNumber numberWithInteger:floorf([[NSDate date] timeIntervalSince1970])] stringValue] forKey:@"oauth_timestamp"];
    
    [parameters setValue:NSStringFromAFOAuthSignatureMethod(self.signatureMethod) forKey:@"oauth_signature_method"];
    
    [parameters setValue:kAFOAuth1Version forKey:@"oauth_version"];
    
    [parameters setValue:[callbackURL absoluteString] forKey:@"oauth_callback"];
    
    
    NSMutableURLRequest *mutableRequest = [self requestWithMethod:@"GET" path:path parameters:parameters];
    [mutableRequest setHTTPMethod:accessMethod];
    
    [parameters setValue:AFSignatureUsingMethodWithSignatureWithConsumerSecretAndRequestTokenSecret(mutableRequest, self.signatureMethod, self.secret, nil, self.stringEncoding) forKey:@"oauth_signature"];
    
    [parameters setValue:[callbackURL absoluteString] forKey:@"oauth_callback"];
    
    
    NSArray *sortedComponents = [[AFQueryStringFromParametersWithEncoding(parameters, self.stringEncoding) componentsSeparatedByString:@"&"] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSMutableArray *mutableComponents = [NSMutableArray array];
    for (NSString *component in sortedComponents) {
        NSArray *subcomponents = [component componentsSeparatedByString:@"="];
        [mutableComponents addObject:[NSString stringWithFormat:@"%@=\"%@\"", subcomponents[0], subcomponents[1]]];
    }
    
    NSString *oauthString = [NSString stringWithFormat:@"OAuth %@", [mutableComponents componentsJoinedByString:@", "]];
    
    NSLog(@"OAuth: %@", oauthString);
    
    [self setDefaultHeader:@"Authorization" value:oauthString];
    
    void (^success_block)(AFHTTPRequestOperation*, id);
    void (^failure_block)(AFHTTPRequestOperation*, id);
    
    success_block = ^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"Success: %@", operation.responseString);
        
        if (success) {
            AFOAuth1Token *requestToken = [[AFOAuth1Token alloc] initWithQueryString:operation.responseString];
            success(requestToken);
        }
    };
    
    failure_block = ^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"Failure: %@", operation.responseString);
        if (failure) {
            failure(error);
        }
    };
    
    if ([accessMethod isEqualToString:@"POST"]) {
        [self postPath:path parameters:nil success:success_block failure:failure_block];
    } else {
        [self getPath:path parameters:parameters success:success_block failure:failure_block];
    }
}

- (void)acquireOAuthAccessTokenWithPath:(NSString *)path
                           requestToken:(AFOAuth1Token *)requestToken
                           accessMethod:(NSString *)accessMethod
                                success:(void (^)(AFOAuth1Token *accessToken))success 
                                failure:(void (^)(NSError *error))failure
{
    [self clearAuthorizationHeader];
    
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    [parameters setValue:kAFOAuth1Version forKey:@"oauth_version"];
    [parameters setValue:NSStringFromAFOAuthSignatureMethod(self.signatureMethod) forKey:@"oauth_signature_method"];
    [parameters setValue:self.key forKey:@"oauth_consumer_key"];
    [parameters setValue:requestToken.key forKey:@"oauth_token"];
    [parameters setValue:requestToken.verifier forKey:@"oauth_verifier"];
    [parameters setValue:[[NSNumber numberWithInteger:floorf([[NSDate date] timeIntervalSince1970])] stringValue] forKey:@"oauth_timestamp"];
    [parameters setValue:AFNounce() forKey:@"oauth_nonce"];

    if (self.realm) {
        [parameters setValue:self.realm forKey:@"realm"];
    }
    
    NSMutableURLRequest *mutableRequest = [self requestWithMethod:accessMethod path:path parameters:parameters];
    [parameters setValue:AFSignatureUsingMethodWithSignatureWithConsumerSecretAndRequestTokenSecret(mutableRequest, self.signatureMethod, self.secret, requestToken.secret, self.stringEncoding) forKey:@"oauth_signature"];
    
    NSArray *sortedComponents = [[AFQueryStringFromParametersWithEncoding(parameters, self.stringEncoding) componentsSeparatedByString:@"&"] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSMutableArray *mutableComponents = [NSMutableArray array];
    for (NSString *component in sortedComponents) {
        NSArray *subcomponents = [component componentsSeparatedByString:@"="];
        [mutableComponents addObject:[NSString stringWithFormat:@"%@=\"%@\"", [subcomponents objectAtIndex:0], [subcomponents objectAtIndex:1]]];
    }
    NSString *oauthString = [NSString stringWithFormat:@"OAuth %@", [mutableComponents componentsJoinedByString:@", "]];
        
    [self setDefaultHeader:@"Authorization" value:oauthString];

    NSMutableURLRequest *request = [self requestWithMethod:accessMethod path:path parameters:parameters];
    AFHTTPRequestOperation *operation = [self HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSLog(@"Success: %@", operation.responseString);

        if (success) {
            AFOAuth1Token *accessToken = [[AFOAuth1Token alloc] initWithQueryString:operation.responseString];
            self.accessToken = accessToken;
            success(accessToken);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"Failure: %@", error);

        if (failure) {
            failure(error);
        }
    }];

    [self enqueueHTTPRequestOperation:operation];
}

#pragma mark - AFHTTPClient

- (NSMutableURLRequest *)requestWithMethod:(NSString *)method path:(NSString *)path parameters:(NSDictionary *)parameters {
    NSMutableURLRequest *request = [super requestWithMethod:method path:path parameters:parameters];
    [request setHTTPShouldHandleCookies:NO];

    return request;
}

//- (AFHTTPRequestOperation *)HTTPRequestOperationWithRequest:(NSURLRequest *)urlRequest
//                                                    success:(void (^)(AFHTTPRequestOperation *, id))success
//                                                    failure:(void (^)(AFHTTPRequestOperation *, NSError *))failure
//{
//    if (self.accessToken) {
//        if ([self.oauthAccessMethod isEqualToString:@"GET"])
//            parameters = [self signCallWithHttpGetWithPath:path andParameters:parameters andMethod:@"GET"];
//        else
//            [self signCallPerAuthHeaderWithPath:path andParameters:parameters andMethod:@"GET"];
//    }
//
//    AFHTTPRequestOperation *operation = [super HTTPRequestOperationWithRequest:urlRequest success:success failure:failure];
//}

//#pragma mark -
//
//- (void)getPath:(NSString *)path 
//     parameters:(NSDictionary *)parameters 
//        success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
//        failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
//{
//    if (self.accessToken) {
//        if ([self.oauthAccessMethod isEqualToString:@"GET"])
//            parameters = [self signCallWithHttpGetWithPath:path andParameters:parameters andMethod:@"GET"];
//        else 
//            [self signCallPerAuthHeaderWithPath:path andParameters:parameters andMethod:@"GET"];
//    }
//    [super getPath:path parameters:parameters success:success failure:failure];
//}
//
//- (void)postPath:(NSString *)path 
//      parameters:(NSDictionary *)parameters 
//         success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
//         failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
//{
//    if (self.accessToken) {
//        if ([self.oauthAccessMethod isEqualToString:@"GET"])
//            parameters = [self signCallWithHttpGetWithPath:path andParameters:parameters andMethod:@"POST"];
//        else 
//            [self signCallPerAuthHeaderWithPath:path andParameters:parameters andMethod:@"POST"];
//    }
//    [super postPath:path parameters:parameters success:success failure:failure];
//}
//
//- (void)putPath:(NSString *)path 
//     parameters:(NSDictionary *)parameters 
//        success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
//        failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
//{
//    if (self.accessToken) {
//        if ([self.oauthAccessMethod isEqualToString:@"GET"])
//            parameters = [self signCallWithHttpGetWithPath:path andParameters:parameters andMethod:@"PUT"];
//        else 
//            [self signCallPerAuthHeaderWithPath:path andParameters:parameters andMethod:@"PUT"];
//    }
//    [super putPath:path parameters:parameters success:success failure:failure];
//}
//
//- (void)deletePath:(NSString *)path 
//        parameters:(NSDictionary *)parameters 
//           success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
//           failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
//{
//    if (self.accessToken) {
//        if ([self.oauthAccessMethod isEqualToString:@"GET"])
//            parameters = [self signCallWithHttpGetWithPath:path andParameters:parameters andMethod:@"DELETE"];
//        else 
//            [self signCallPerAuthHeaderWithPath:path andParameters:parameters andMethod:@"DELETE"];
//    }
//    [super deletePath:path parameters:parameters success:success failure:failure];
//}
//
//- (void)patchPath:(NSString *)path 
//       parameters:(NSDictionary *)parameters 
//          success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
//          failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
//{
//    if (self.accessToken) {
//        if ([self.oauthAccessMethod isEqualToString:@"GET"])
//            parameters = [self signCallWithHttpGetWithPath:path andParameters:parameters andMethod:@"PATCH"];
//        else 
//            [self signCallPerAuthHeaderWithPath:path andParameters:parameters andMethod:@"PATCH"];
//    }
//    [super patchPath:path parameters:parameters success:success failure:failure];
//}

- (NSMutableDictionary *)paramsWithOAuthFromParams:(NSDictionary *)parameters {
    NSMutableDictionary *params = nil;
    if (parameters)
        params = [parameters mutableCopy];
    else {
        params = [NSMutableDictionary dictionaryWithCapacity:7];
    }
    [params setValue:self.key forKey:@"oauth_consumer_key"];
    [params setValue:self.accessToken.key forKey:@"oauth_token"];
    [params setValue:NSStringFromAFOAuthSignatureMethod(self.signatureMethod) forKey:@"oauth_signature_method"];
    [params setValue:[[NSNumber numberWithInteger:floorf([[NSDate date] timeIntervalSince1970])] stringValue] forKey:@"oauth_timestamp"];
    [params setValue:AFNounce() forKey:@"oauth_nonce"];
    [params setValue:kAFOAuth1Version forKey:@"oauth_version"];
    return params;
}

- (void) signCallPerAuthHeaderWithPath:(NSString *)path usingParameters:(NSMutableDictionary *)parameters andMethod:(NSString *)method {
    NSMutableURLRequest *request = [self requestWithMethod:@"GET" path:path parameters:parameters];
    [request setHTTPMethod:method];
    [parameters setValue:AFSignatureUsingMethodWithSignatureWithConsumerSecretAndRequestTokenSecret(request, self.signatureMethod, self.secret, self.accessToken.secret, self.stringEncoding) forKey:@"oauth_signature"];
    
    
    NSArray *sortedComponents = [[AFQueryStringFromParametersWithEncoding(parameters, self.stringEncoding) componentsSeparatedByString:@"&"] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSMutableArray *mutableComponents = [NSMutableArray array];
    for (NSString *component in sortedComponents) {
        NSArray *subcomponents = [component componentsSeparatedByString:@"="];
        [mutableComponents addObject:[NSString stringWithFormat:@"%@=\"%@\"", subcomponents[0], subcomponents[1]]];
    }
    
    NSString *oauthString = [NSString stringWithFormat:@"OAuth %@", [mutableComponents componentsJoinedByString:@", "]];
    
    NSLog(@"OAuth: %@", oauthString);
    
    [self setDefaultHeader:@"Authorization" value:oauthString];
}

- (void) signCallPerAuthHeaderWithPath:(NSString *)path andParameters:(NSDictionary *)parameters andMethod:(NSString *)method {
    NSMutableDictionary *params = [self paramsWithOAuthFromParams:parameters];
    [self signCallPerAuthHeaderWithPath:path usingParameters:params andMethod:method];
}

- (NSDictionary *) signCallWithHttpGetWithPath:(NSString *)path andParameters:(NSDictionary *)parameters andMethod:(NSString *)method {
    NSMutableDictionary *params = [self paramsWithOAuthFromParams:parameters];
    [self signCallPerAuthHeaderWithPath:path usingParameters:params andMethod:method];
    return params;
}

@end
