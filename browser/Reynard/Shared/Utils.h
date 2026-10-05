//
//  Utils.h
//  Reynard
//
//  Created by Minh Ton on 12/4/26.
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

BOOL getEntitlementValue(NSString *key);
NSArray<NSDictionary<NSString *, NSString *> *> *ReynardCopyInstalledApplications(void);
void updateJetsamControl(pid_t pid);
int spawnRoot(NSString *path, NSArray<NSString *> *args);

NS_ASSUME_NONNULL_END
