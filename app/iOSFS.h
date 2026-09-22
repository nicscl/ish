//
//  iOSFS.h
//  iSH
//
//  Created by Noah Peeters on 26.10.19.
//

extern const struct fs_ops iosfs;
extern const struct fs_ops iosfs_unsafe;

void iosfs_init(void);
void iosfs_clear_all_bookmarks(void); // for recovery
#ifdef __OBJC__
// Mount points of the iOS folders currently mounted (and remembered), sorted.
NSArray<NSString *> *iosfs_mount_points(void);
#endif
