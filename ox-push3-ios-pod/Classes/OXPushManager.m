//
//  OXPushManager.m
//  oxPush2-IOS
//
//  Created by Nazar Yavornytskyy on 2/9/16.
//  Copyright © 2016 Nazar Yavornytskyy. All rights reserved.
//

#import "OXPushManager.h"
#import "OxPush2Request.h"
#import "ApiServiceManager.h"
#import "DataStoreManager.h"
#import "TokenEntity.h"
#import "U2fMetaData.h"
#import "TokenManager.h"
#import "Constants.h"
#import "Base64.h"
#import "NSString+URLEncode.h"
#import "TokenDevice.h"
#import "UserLoginInfo.h"

#define ENROLL_METHOD @"enroll"
#define AUTHENTICATE_METHOD @"authenticate"

@implementation OXPushManager

-(void)onOxPushApproveRequest:(NSDictionary*)parameters isDecline:(BOOL)isDecline isSecureClick:(BOOL)isSecureClick callback:(RequestCompletionHandler)handler{
    NSString* app = [parameters objectForKey:APP];
    NSString* state = [parameters objectForKey:STATE];
    NSString* enrollment = [parameters objectForKey:ENROLLMENT];
    NSString* created = [NSString stringWithFormat:@"%@", [NSDate date]];//[parameters objectForKey:@"created"];
    NSString* issuer = [parameters objectForKey:ISSUER];
    NSString* username = [parameters objectForKey:USERNAME];
    NSString* method = [parameters objectForKey:METHOD];
    oneStep = username == nil ? YES : NO;
    if (app != nil && created != nil && issuer != nil){
        OxPush2Request* oxRequest = [[OxPush2Request alloc] initWithName:username app:app issuer:issuer state:state == nil ? @"" : state method:@"GET" created:created];
        oxRequest.enrollment = enrollment == nil ? @"" : enrollment;
        NSMutableDictionary* parameters = [[NSMutableDictionary alloc] init];
        [parameters setObject:[oxRequest app] forKey:@"application"];
        if (!oneStep){
            [parameters setObject:[oxRequest userName] forKey:@"username"];
        }
        [[ApiServiceManager sharedInstance] doRequest:oxRequest callback:^(NSDictionary *result,NSError *error){
            if (error) {
                handler(nil , error);
            } else {
                    // Success getting U2fMetaData
                NSString* version = [result objectForKey:@"version"];
                NSString* issuer = [result objectForKey:@"issuer"];
                NSString* authenticationEndpoint = [result objectForKey:@"authentication_endpoint"];
                NSString* registrationEndpoint = [result objectForKey:@"registration_endpoint"];
                
                    //Check if we're using cred manager - in that case "state"== null and we should use "enrollment" parameter
                if (![[oxRequest enrollment] isEqualToString:@""]){
                    [parameters setObject:[oxRequest enrollment] forKey:@"enrollment_code"];
                } else {
                        //Check is old or new version of server
                    NSString* state_key = [authenticationEndpoint containsString:@"seam"] ? @"session_state" : @"session_id";
                    [parameters setObject:[oxRequest state] forKey:state_key];
                }
                
                U2fMetaData* u2fMetaData = [[U2fMetaData alloc] initWithVersion:version issuer:issuer authenticationEndpoint:authenticationEndpoint registrationEndpoint:registrationEndpoint];

                NSString* u2fEndpoint = [[NSString alloc] init];
                BOOL isEnroll = [method isEqualToString:ENROLL_METHOD];
                if (isEnroll){//registration
                    u2fEndpoint = [u2fMetaData registrationEndpoint];
                } else {//authentication
                    u2fEndpoint = [u2fMetaData authenticationEndpoint];
                }
                
                if (!oneStep && !isEnroll) {
                    __block BOOL isResult = NO;
                    
					TokenEntity* tokenEntity = [[DataStoreManager sharedInstance] getTokenEntityForApplication:app userName:username];
					if (tokenEntity == nil) {
						NSError *err = [[NSError alloc] init];
						err.message = "No token found for this application. Please remove this device and re-enroll it.";
						handler(nil, err);
						return;
					}
				
					if (tokenEntity.keyHandle != nil) {
						[parameters setObject:tokenEntity.keyHandle forKey:@"keyhandle"];
					}

                    [[ApiServiceManager sharedInstance] doGETUrl:u2fEndpoint :parameters callback:^(NSDictionary *result,NSError *error){
                        if (error) {
                            handler(nil , error);
                        } else {
                                // Success
                            isResult = YES;
                            [self callServiceChallenge:u2fEndpoint isEnroll:isEnroll andParameters:parameters isDecline:isDecline isSecureClick: isSecureClick userName: username callback:^(NSDictionary *result,NSError *error){
                                if (error) {
                                    handler(nil , error);
                                    return;
                                } else {
                                        //Success
                                    handler(result ,nil);
                                }
                            }];
                        }
                    }];
                } else {
                    
                    [self callServiceChallenge:u2fEndpoint isEnroll:isEnroll andParameters:parameters isDecline:isDecline isSecureClick:isSecureClick userName: username callback:^(NSDictionary *result,NSError *error){
                        if (error) {
                            handler(nil , error);
                        } else {
                                //Success
                            handler(result ,nil);
                        }
                    }];
                }
            }
        }];
    }
}

-(void)callServiceChallenge:(NSString*)baseUrl isEnroll:(BOOL)isEnroll andParameters:(NSDictionary*)parameters isDecline:(BOOL)isDecline isSecureClick:(BOOL)isSecureClick userName:(NSString*)userName callback:(RequestCompletionHandler)handler{
    [[ApiServiceManager sharedInstance] doGETUrl:baseUrl :parameters callback:^(NSDictionary *result,NSError *error){
        if (error) {
            handler(nil, error);
        } else {
            // Success getting authenticate MetaData
            [self onChallengeReceived:baseUrl isEnroll:isEnroll metaData:result isDecline:isDecline isSecureClick:isSecureClick userName: userName callback:(RequestCompletionHandler)handler];
        }
    }];
}

-(void)onChallengeReceived:(NSString*)baseUrl isEnroll:(BOOL)isEnroll metaData:(NSDictionary*)result isDecline:(BOOL)isDecline isSecureClick:(BOOL)isSecureClick userName:(NSString*)userName callback:(RequestCompletionHandler)handler{
    TokenManager* tokenManager = [[TokenManager alloc] init];
    tokenManager.u2FKey = [[U2FKeyImpl alloc] init];
    if (isEnroll){
        [tokenManager enroll:result baseUrl:baseUrl isDecline:isDecline isSecureClick: isSecureClick callBack:^(TokenResponse *tokenResponse, NSError *error){
            [self handleTokenResponse:tokenResponse baseUrl:baseUrl isDecline:isDecline callback:handler];
        }];
    } else {
        [tokenManager sign:result baseUrl:baseUrl isDecline:isDecline isSecureClick:isSecureClick userName: userName callBack:^(TokenResponse* tokenResponse, NSError *error){
            [self handleTokenResponse:tokenResponse baseUrl:baseUrl isDecline:isDecline callback:handler];
        }];
    }
}

-(void)callServiceAuthenticateToken:(NSString*)baseUrl andParameters:(NSDictionary*)parameters isDecline:(BOOL)isDecline callback:(RequestCompletionHandler)handler{
    [[ApiServiceManager sharedInstance] callPOSTMultiPartAPIService:baseUrl andParameters:parameters isDecline:isDecline callback:^(NSDictionary *result,NSError *error){
        if (error) {
            handler(nil , error);
        } else {
            //Success
            handler(result ,nil);
        }
    }];
}

-(void)handleTokenResponse:(TokenResponse*) tokenResponse baseUrl:(NSString*)baseUrl isDecline:(BOOL)isDecline callback:(RequestCompletionHandler)handler {
    if (tokenResponse == nil){
        handler(nil , nil);
        [UserLoginInfo sharedInstance].logState = LOGIN_FAILED;
        [[DataStoreManager sharedInstance] saveUserLoginInfo:[UserLoginInfo sharedInstance]];
    } else {
        NSMutableDictionary* tokenParameters = [[NSMutableDictionary alloc] init];
        [tokenParameters setObject:@"username" forKey:@"username"];
        [tokenParameters setObject:[tokenResponse response] forKey:@"tokenResponse"];
        [self callServiceAuthenticateToken:baseUrl andParameters:tokenParameters isDecline:isDecline callback:^(NSDictionary *result,NSError *error){
            if (error) {
                handler(nil , error);
            } else {
                //Success
                handler(result ,nil);
            }
        }];
    }
}

-(NSDictionary*)getStep{
    NSDictionary* userInfo = @{@"oneStep": @(oneStep)};
    return userInfo;
}

-(void)setDevicePushToken:(NSString*)devicePushToken{
    [TokenDevice sharedInstance].deviceToken = devicePushToken;
}

-(NSArray*)getLogs{
    return [[DataStoreManager sharedInstance] getUserLoginInfo];
}

-(NSArray*)getKeys{
    return [[DataStoreManager sharedInstance] getTokenEntities];
}

@end
