/*
 * Copyright 2010-present Facebook.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FBAccessTokenData.h"
#import "FBError.h"
#import "FBIntegrationTests.h"
#import "FBRequest.h"
#import "FBRequestConnection+Internal.h"
#import "FBRequestConnection.h"
#import "FBSession+Internal.h"
#import "FBTestBlocker.h"
#import "FBTestSession+Internal.h"
#import "FBTestSession.h"

#if defined(FACEBOOKSDK_SKIP_REQUEST_CONNECTION_TESTS)

#pragma message ("warning: Skipping FBRequestConnectionIntegrationTests")

#else

@interface FBRequestConnectionIntegrationTests : FBIntegrationTests
@end

@implementation FBRequestConnectionIntegrationTests

- (void)testCancelInvokesHandler {
    FBRequest *request = [[[FBRequest alloc] initWithSession:self.defaultTestSession graphPath:@"me"] autorelease];
    FBRequestConnection *connection = [[FBRequestConnection alloc] init];
    __block int count = 0;
    __block FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    
    [connection addRequest:request completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
        XCTAssertEqual(FBErrorOperationCancelled, error.code, @"Expected FBErrorOperationCancelled code for error:%@", error);
        XCTAssertEqual(++count, 1, @"Expected handler to only be called once");
        [blocker signal];
    }];
    [connection start];
    [connection cancel];
    
    XCTAssertTrue([blocker waitWithTimeout:10], @" handler was not invoked");
    
    [connection release];
}

- (void)testConcurrentRequests
{
    __block FBTestBlocker *blocker1 = [[FBTestBlocker alloc] init];
    __block FBTestBlocker *blocker2 = [[FBTestBlocker alloc] init];
    __block FBTestBlocker *blocker3 = [[FBTestBlocker alloc] init];
    [[[[FBRequest alloc] initWithSession:self.defaultTestSession graphPath:@"me"] autorelease] startWithCompletionHandler:[self handlerExpectingSuccessSignaling:blocker1]];
    [[[[FBRequest alloc] initWithSession:self.defaultTestSession graphPath:@"me"] autorelease] startWithCompletionHandler:[self handlerExpectingSuccessSignaling:blocker2]];
    [[[[FBRequest alloc] initWithSession:self.defaultTestSession graphPath:@"me"] autorelease] startWithCompletionHandler:[self handlerExpectingSuccessSignaling:blocker3]];
    
    [blocker1 wait];
    [blocker2 wait];
    [blocker3 wait];
    
    [blocker1 release];
    [blocker2 release];
    [blocker3 release];
}

- (void)testWillPiggybackTokenExtensionIfNeeded
{
    FBTestSession *session = [self getSessionWithSharedUserWithPermissions:nil];
    session.forceAccessTokenRefresh = YES;
    // Invoke shouldRefreshPermissions which has the side affect of disabling permissions refresh piggybacking for an hour.
    [session shouldRefreshPermissions];
    
    FBRequest *request = [[[FBRequest alloc] initWithSession:session graphPath:@"me"] autorelease];
    
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    FBRequestConnection *connection = [[FBRequestConnection alloc] init];
    [connection addRequest:request completionHandler:[self handlerExpectingSuccessSignaling:blocker]];
    [connection start];
    
    [blocker wait];
    [blocker release];
    
    NSArray *requests = [connection performSelector:@selector(requests)];

    // Therefore, only expect the the token refresh piggyback in addition to the original request for /me
    int count = requests.count;
    XCTAssertEqual(2,count, @"unexpected number of piggybacks");
    
    [connection release];
}

- (void)testWillPiggybackPermissionsRefresh
{
    FBTestSession *session = [self getSessionWithSharedUserWithPermissions:nil];
    session.forceAccessTokenRefresh = YES;
    // verify session's permissions refresh date is initially in the past.
    XCTAssertEqual([NSDate distantPast], session.accessTokenData.permissionsRefreshDate, @"session permission refresh date does not match");
    
    FBRequest *request = [[[FBRequest alloc] initWithSession:session graphPath:@"me"] autorelease];
    
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    FBRequestConnection *connection = [[FBRequestConnection alloc] init];
    [connection addRequest:request completionHandler:[self handlerExpectingSuccessSignaling:blocker]];
    [connection start];
    
    [blocker wait];
    [blocker release];
    
    NSArray *requests = [connection performSelector:@selector(requests)];

    // Expect the token refresh and permission refresh to be piggybacked.
    int count = requests.count;
    XCTAssertEqual(3,count, @"unexpected number of piggybacks");
    
    [connection release];
    
    XCTAssertTrue([session.accessTokenData.permissionsRefreshDate timeIntervalSinceNow]> -3, @"session permission refresh date should be within a few seconds of now");
}

// a test to make sure the permissions refresh request will no-op
// if the session had been closed.
- (void)testPiggybackPermissionsRefreshNoopForClosedSession
{
    id session = [OCMockObject partialMockForObject:[self getSessionWithSharedUserWithPermissions:nil]];
    [session setForceAccessTokenRefresh:YES];

    //partial mock the session so we can make sure session is closed and `handleRefreshPermissions` should do nothing.
    [[[session stub] andDo:^(NSInvocation *invocation) {
        XCTAssertFalse([session isOpen], @"session should not be open at this point!");
    }] handleRefreshPermissions:[OCMArg any]];

    // verify session's permissions refresh date is initially in the past.
    XCTAssertEqual([NSDate distantPast], [session accessTokenData].permissionsRefreshDate, @"session permission refresh date does not match");

    FBRequest *request = [[[FBRequest alloc] initWithSession:session graphPath:@"me"] autorelease];

    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    FBRequestConnection *connection = [[FBRequestConnection alloc] init];
    [connection addRequest:request completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
        XCTAssertTrue(!error, @"got unexpected error");
        XCTAssertNotNil(result, @"didn't get expected result");
        [blocker signal];
        // Close the session, which should result in the piggyback handlers doing nothing!
        [session closeAndClearTokenInformation];
    }];
    [connection start];

    [blocker wait];
    [blocker release];
    [connection release];

    XCTAssertTrue([[session accessTokenData].permissionsRefreshDate timeIntervalSinceNow]> -3, @"session permission refresh date should be within a few seconds of now");
}

- (void)testCachedRequests
{
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    
    FBTestSession *session = [self getSessionWithSharedUserWithPermissions:nil];
    
    // here we just want to seed the cache, by identifying the cache, and by choosing not to consult the cache
    FBRequestConnection *connection = [[FBRequestConnection alloc] init];    
    FBRequest *request = [[[FBRequest alloc] initWithSession:session graphPath:@"me"] autorelease];
    [request.parameters setObject:@"id,first_name" forKey:@"fields"];
    [connection addRequest:request completionHandler:[self handlerExpectingSuccessSignaling:blocker]];
    [connection startWithCacheIdentity:@"FBUnitTests"
                 skipRoundtripIfCached:NO];
    
    [blocker wait];
    
    XCTAssertFalse(connection.isResultFromCache, @"Should not have cached, and should have fetched from server");
    
    [connection release];
    [blocker release];
    
    __block BOOL completedWithoutBlocking = NO;
    
    // here we expect to complete on the cache, so we will confirm that
    connection = [[FBRequestConnection alloc] init];    
    request = [[[FBRequest alloc] initWithSession:session graphPath:@"me"] autorelease];
    [request.parameters setObject:@"id,first_name" forKey:@"fields"];
    [connection addRequest:request completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
        XCTAssertNotNil(result, @"Expected a successful result");
        completedWithoutBlocking = YES;
        [blocker signal];
    }];
    [connection startWithCacheIdentity:@"FBUnitTests"
                 skipRoundtripIfCached:YES];
    
    // Note despite the skipping of round trip, the completion handler is still dispatched async since we
    // started using the Task framework in FBRequestConnection.
    XCTAssertTrue([blocker waitWithTimeout:3], @"blocker timed out");
    // should have completed successfully by here
    XCTAssertTrue(completedWithoutBlocking, @"Should have called the handler, due to cache hit");
    XCTAssertTrue(connection.isResultFromCache, @"Should not have fetched from server");
    [connection release];
}

- (void)testDelete
{
    // this is a longish test, here is the breakdown:
    // 1) three objects are created in one batch
    // 2) two objects are deleted with different approaches, and one object created in the next batch
    // 3) one object is deleted
    // 4) another object is deleted
    FBTestBlocker *blocker = [[[FBTestBlocker alloc] initWithExpectedSignalCount:3] autorelease];
    
    FBTestSession *session = [self getSessionWithSharedUserWithPermissions:nil];
    
    FBRequest *request = [[[FBRequest alloc] initWithSession:session
                                                   graphPath:@"me/feed"]
                          autorelease];
    
    [request.parameters setObject:@"dummy status"
                           forKey:@"name"];
    [request.parameters setObject:@"http://www.facebook.com"
                           forKey:@"link"];
    [request.parameters setObject:@"dummy description"
                           forKey:@"description"];
    [request.parameters setObject:@"post"
                           forKey:@"method"];
    
    NSMutableArray *fbids = [NSMutableArray array];
    
    FBRequestHandler handler = ^(FBRequestConnection *connection, id<FBGraphObject> result, NSError *error) {
        // There's a lot going on in this test. To make failures easier to understand, giving each
        // of the handlers a number so we can tell what failed.
        XCTAssertNotNil(result, @"should have a result here: Handler 1");
        XCTAssertNil(error, @"should not have an error here: Handler 1");
        [fbids addObject: [[result objectForKey:@"id"] description]];
        [blocker signal];
    };
    
    // this creates three objects
    FBRequestConnection *connection = [[[FBRequestConnection alloc] init] autorelease];
    [connection addRequest:request completionHandler:handler];
    [connection addRequest:request completionHandler:handler];
    [connection addRequest:request completionHandler:handler];
    [connection start];
    
    [blocker wait];
    
    if (fbids.count != 3) {
        XCTAssertTrue(fbids.count == 3, @"wrong number of fbids, aborting test");
        // Things are bad. Continuing isn't going to make them better, and might throw exceptions.
        return;
    }
    
    blocker = [[FBTestBlocker alloc] initWithExpectedSignalCount:3];
    
    connection = [[[FBRequestConnection alloc] init] autorelease];
    FBRequest *deleteRequest = [[FBRequest alloc] initWithSession:session
                                                        graphPath:[fbids objectAtIndex:fbids.count-1]
                                                       parameters:nil
                                                       HTTPMethod:@"delete"];
    [connection addRequest:deleteRequest
         completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
             XCTAssertNotNil(result, @"should have a result here: Handler 2");
             XCTAssertNil(error, @"should not have an error here: Handler 2");
             XCTAssertTrue(0 != fbids.count, @"not enough fbids: Handler 2");
             [fbids removeObjectAtIndex:fbids.count-1];
             [blocker signal];             
         }];
    
    deleteRequest = [[FBRequest alloc] initWithSession:session
                                             graphPath:[fbids objectAtIndex:fbids.count-1]
                                            parameters:[NSDictionary dictionaryWithObjectsAndKeys:
                                                        @"delete", @"method",
                                                        nil]
                                            HTTPMethod:nil];
    [connection addRequest:deleteRequest
         completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
             XCTAssertNotNil(result, @"should have a result here: Handler 3");
             XCTAssertNil(error, @"should not have an error here: Handler 3");
             XCTAssertTrue(0 != fbids.count, @"not enough fbids: Handler 3");
             [fbids removeObjectAtIndex:fbids.count-1];
             [blocker signal];             
         }];
    
    [connection addRequest:request completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
        XCTAssertNotNil(result, @"should have a result here: Handler 4");
        XCTAssertNil(error, @"should not have an error here: Handler 4");
        if (result) {
            [fbids addObject: [[result objectForKey:@"id"] description]];
        }
        [blocker signal];
    }];
    
    // these deletes two and adds one
    [connection start];
    
    [blocker wait];
    if (fbids.count != 2) {
        XCTAssertTrue(fbids.count == 2, @"wrong number of fbids, aborting test");
        // Things are bad. Continuing isn't going to make them better, and might throw exceptions.
        return;
    }
    
    blocker = [[[FBTestBlocker alloc] initWithExpectedSignalCount:2] autorelease];
    
    // delete
    request = [[[FBRequest alloc] initWithSession:session
                                        graphPath:[fbids objectAtIndex:fbids.count-1]
                                       parameters:[NSDictionary dictionaryWithObjectsAndKeys:
                                                   @"delete", @"method",
                                                   nil]
                                       HTTPMethod:nil] autorelease];
    [request startWithCompletionHandler:
     ^(FBRequestConnection *innerConnection, id result, NSError *error) {
         XCTAssertNotNil(result, @"should have a result here: Handler 5");
         XCTAssertNil(error, @"should not have an error here: Handler 5");
         XCTAssertTrue(0 != fbids.count, @"not enough fbids: Handler 5");
         [fbids removeObjectAtIndex:fbids.count-1];
         [blocker signal];
     }];
    // delete
    request = [[[FBRequest alloc] initWithSession:session
                                        graphPath:[fbids objectAtIndex:fbids.count-1] 
                                       parameters:nil 
                                       HTTPMethod:@"delete"] autorelease];
    [request startWithCompletionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
        XCTAssertNotNil(result, @"should have a result here: Handler 6");
        XCTAssertNil(error, @"should not have an error here: Handler 6");
        XCTAssertTrue(0 != fbids.count, @"not enough fbids: Handler 6");
        [fbids removeObjectAtIndex:fbids.count-1];
        [blocker signal];
    }];
    
    [blocker wait];
    
    XCTAssertTrue(fbids.count == 0, @"Our fbid collection should be empty here");
}

- (void)testNilCompletionHandler {
    /*
     Need to test that nil completion handlers don't cause crashes, and also don't prevent the request from completing.
     We'll do this via the following steps:
     1. Create a post on me/feed with a valid handler and get the id.
     2. Delete the post without a handler
     3. Try delete the post again with a valid handler and make sure we get an error since Step #2 should have deleted
     */
    
    // Step 1
    
    FBTestBlocker *blocker = [[FBTestBlocker alloc] init];
    
    FBTestSession *session = [self getSessionWithSharedUserWithPermissions:nil];
    
    FBRequest *postRequest = [[[FBRequest alloc] initWithSession:session
                                                       graphPath:@"me/feed"]
                              autorelease];
    
    [postRequest.parameters setObject:@"dummy status"
                               forKey:@"name"];
    [postRequest.parameters setObject:@"http://www.facebook.com"
                               forKey:@"link"];
    [postRequest.parameters setObject:@"dummy description"
                               forKey:@"description"];
    [postRequest.parameters setObject:@"post"
                               forKey:@"method"];
    
    NSMutableArray *fbids = [NSMutableArray array];
    
    [postRequest startWithCompletionHandler:^(FBRequestConnection *connection, id result, NSError *error) {
        XCTAssertNotNil(result, @"should have a result here: Post Request handler");
        XCTAssertNil(error, @"should not have an error here: Post Request handler");
        [fbids addObject: [[result objectForKey:@"id"] description]];
        [blocker signal];
    }];
    
    [blocker wait];
    [blocker release];
    
    
    // Step 2
    
    blocker = [[FBTestBlocker alloc] init];
    FBRequest *deleteRequest = [[[FBRequest alloc] initWithSession:session
                                                         graphPath:[fbids objectAtIndex:0]
                                                        parameters:nil
                                                        HTTPMethod:@"delete"] autorelease];
    [deleteRequest startWithCompletionHandler:nil];
    // Can't signal without a handler, so just wait 2 seconds.
    [blocker waitWithTimeout:2];
    [blocker release];
    
    
    // Step 3
    
    blocker = [[FBTestBlocker alloc] init];
    deleteRequest = [[[FBRequest alloc] initWithSession:session
                                              graphPath:[fbids objectAtIndex:0]
                                             parameters:nil
                                             HTTPMethod:@"delete"] autorelease];
    [deleteRequest startWithCompletionHandler:^(FBRequestConnection *connection, id result, NSError *error) {
        XCTAssertNil(result, @"should not have a result here: Dupe-Delete Handler");
        XCTAssertNotNil(error, @"should have an error here: Dupe-Delete Handler");
        [blocker signal];
    }];
    
    [blocker wait];
    [blocker release];
}

- (void)testMultipleSelectionWithDependenciesBatch {
    FBTestSession *session = [self getSessionWithSharedUserWithPermissions:nil];
    FBRequestConnection *connection = [[FBRequestConnection alloc] init];
    FBTestBlocker *blocker = [[FBTestBlocker alloc] initWithExpectedSignalCount:2];

    NSString *graphPath = [NSString stringWithFormat:@"?ids=%@,%@&fields=id", session.testAppID, session.testUserID];
    FBRequest *parent = [[[FBRequest alloc] initWithSession:session graphPath:graphPath] autorelease];
    [connection addRequest:parent
         completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
             XCTAssertNil(error, @"unexpected error in parent request :%@", error);
             [blocker signal];
         } batchEntryName:@"getactions"];

    FBRequest *child = [[[FBRequest alloc] initWithSession:session graphPath:@"?ids={result=getactions:$.*.id}"] autorelease];
    [connection addRequest:child
         completionHandler:^(FBRequestConnection *innerConnection, id result, NSError *error) {
             XCTAssertNil(error, @"unexpected error in child request :%@", error);
             XCTAssertNotNil(result, @"expected results");
             [blocker signal];
         } batchEntryName:nil];
    [connection start];
    [connection release];

    XCTAssertTrue([blocker waitWithTimeout:60], @"blocker timed out");
}
@end

#endif
