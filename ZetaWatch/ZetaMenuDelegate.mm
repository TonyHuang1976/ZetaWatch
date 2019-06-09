//
//  ZetaMenuDelegate.mm
//  ZetaWatch
//
//  Created by Gerhard Röthlin on 2015.12.20.
//  Copyright © 2015 the-color-black.net. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without modification, are permitted
//  provided that the conditions of the "3-Clause BSD" license described in the BSD.LICENSE file are met.
//  Additional licensing options are described in the README file.
//

#import "ZetaMenuDelegate.h"
#import "ZetaImportMenuDelegate.h"
#import "ZetaPoolWatcher.h"
#import "ZetaAuthorization.h"

#include "ZFSUtils.hpp"
#include "ZFSStrings.hpp"

#include <type_traits>
#include <iomanip>
#include <sstream>
#include <chrono>

@interface ZetaMenuDelegate ()
{
	NSMutableArray * _dynamicMenus;
	ZetaPoolWatcher * _watcher;
}

@end

@implementation ZetaMenuDelegate

- (id)init
{
	if (self = [super init])
	{
		_dynamicMenus = [[NSMutableArray alloc] init];
		_watcher = [[ZetaPoolWatcher alloc] init];
		_watcher.delegate = self;
	}
	return self;
}

- (void)menuNeedsUpdate:(NSMenu*)menu
{
	[self clearDynamicMenu:menu];
	[self createPoolMenu:menu];
	[self createActionMenu:menu];
}

#pragma mark Formating

NSString * formatErrorStat(zfs::VDevStat stat)
{
	NSString * status = zfs::localized_describe_vdev_state_t(stat.state, stat.aux);
	NSString * errors = nil;
	if (stat.errorRead == 0 && stat.errorWrite == 0 && stat.errorChecksum == 0)
	{
		errors = NSLocalizedString(@"No Errors", @"Format vdev_stat_t");
	}
	else
	{
		NSString * format = NSLocalizedString(@"%llu Read Errors, %llu Write Errors, %llu Checksum Errors", @"Format vdev_stat_t");
		errors = [NSString stringWithFormat:format, stat.errorRead, stat.errorWrite, stat.errorChecksum];
	}
	return [NSString stringWithFormat:@"%@, %@", status, errors];
}

struct MetricPrefix
{
	uint64_t factor;
	char const * prefix;
};

MetricPrefix metricPrefixes[] = {
	{ 1000000000000000000, "E" },
	{    1000000000000000, "P" },
	{       1000000000000, "T" },
	{	       1000000000, "G" },
	{             1000000, "M" },
	{                1000, "k" },
};

size_t prefixCount = std::extent<decltype(metricPrefixes)>::value;

template<typename T>
std::string formatPrefixedValue(T size)
{
	for (size_t p = 0; p < prefixCount; ++p)
	{
		if (size > metricPrefixes[p].factor)
		{
			double scaledSize = size / double(metricPrefixes[p].factor);
			std::stringstream ss;
			ss << std::setprecision(2) << std::fixed << scaledSize << " " << metricPrefixes[p].prefix;
			return ss.str();
		}
	}
	return std::to_string(size) + " ";
}

template<typename T>
std::string formatBytes(T bytes)
{
	return formatPrefixedValue(bytes) + "B";
}

std::chrono::seconds getElapsed(zfs::ScanStat const & scanStat)
{
	auto elapsed = time(0) - scanStat.passStartTime;
	elapsed -= scanStat.passPausedSeconds;
	elapsed = (elapsed > 0) ? elapsed : 1;
	return std::chrono::seconds(elapsed);
}

std::string formatRate(uint64_t bytes, std::chrono::seconds const & time)
{
	return formatBytes(bytes / time.count()) + "/s";
}

std::string formatTimeRemaining(zfs::ScanStat const & scanStat, std::chrono::seconds const & time)
{
	auto bytesRemaining = scanStat.total - scanStat.issued;
	auto issued = scanStat.passIssued;
	if (issued == 0)
		issued = 1;
	auto secondsRemaining = bytesRemaining * time.count() / issued;
	std::stringstream ss;
	ss << std::setfill('0');
	ss << (secondsRemaining / (60*60*24)) << " days "
		<< std::setw(2) << ((secondsRemaining / (60*60)) % 24) << ":"
		<< std::setw(2) << ((secondsRemaining / 60) % 60) << ":"
		<< std::setw(2) << (secondsRemaining % 60);
	return ss.str();
}

#pragma mark ZFS Inspection

NSMenu * createFSMenu(zfs::ZFileSystem const & fs, ZetaMenuDelegate * delegate)
{
	NSMenu * fsMenu = [[NSMenu alloc] init];
	[fsMenu setAutoenablesItems:NO];
	if (fs.type() == zfs::ZFileSystem::filesystem)
	{
		NSString * fsName = [NSString stringWithUTF8String:fs.name()];
		NSMenuItem * item;
		auto [encRoot, isRoot] = fs.encryptionRoot();
		if (isRoot && fs.keyStatus() != zfs::ZFileSystem::available)
		{
			item = [fsMenu addItemWithTitle:@"Load Key"
									 action:@selector(loadKey:) keyEquivalent:@""];
			item.representedObject = fsName;
			item.target = delegate;
		}
		if (!fs.mounted())
		{
			item = [fsMenu addItemWithTitle:@"Mount"
									 action:@selector(mountFilesystem:) keyEquivalent:@""];
			item.representedObject = fsName;
			item.target = delegate;
		}
		else
		{
			item = [fsMenu addItemWithTitle:@"Unmount"
									 action:@selector(unmountFilesystem:) keyEquivalent:@""];
			item.representedObject = fsName;
			item.target = delegate;
		}
	}
	return fsMenu;
}

NSString * formatStatus(zfs::ZFileSystem const & fs)
{
	NSString * mountStatus = fs.mounted() ?
		NSLocalizedString(@"📌", @"mounted status") :
		NSLocalizedString(@"🕳", @"unmounted status");
	NSString * encStatus = nil;
	switch (fs.keyStatus())
	{
		case zfs::ZFileSystem::none:
			encStatus = @"";
			break;
		case zfs::ZFileSystem::unavailable:
			encStatus = NSLocalizedString(@", 🔒", @"locked status");
			break;
		case zfs::ZFileSystem::available:
			encStatus = NSLocalizedString(@"🔑", @"unlocked status");
			break;
	}
	NSString * fsLine = [NSString stringWithFormat:NSLocalizedString(@"%s (%@%@)", @"File System Menu Entry"), fs.name(), mountStatus, encStatus];
	return fsLine;
}

NSMenuItem * addVdev(zfs::ZPool const & pool, zfs::NVList const & device, NSMenu * menu)
{
	auto stat = zfs::vdevStat(device);
	NSString * devLine = [NSString stringWithFormat:NSLocalizedString(@"%s [%s] (%@)", @"Device Menu Entry"),
		pool.vdevName(device).c_str(), pool.vdevDevice(device).c_str(), formatErrorStat(stat)];
	NSMenuItem * item = [menu addItemWithTitle:devLine action:nullptr keyEquivalent:@""];
	return item;
}

NSMenu * createVdevMenu(zfs::ZPool const & pool, ZetaMenuDelegate * delegate)
{
	NSMenu * vdevMenu = [[NSMenu alloc] init];
	[vdevMenu setAutoenablesItems:NO];
	try
	{
		auto vdevs = pool.vdevs();
		auto scrub = pool.scanStat();
		if (scrub.state == zfs::ScanStat::scanning)
		{
			auto elapsed = getElapsed(scrub);
			NSString * scanLine0 = [NSString stringWithFormat:NSLocalizedString(
				@"Scrub in Progress:", @"Scrub Menu Entry 0")];
			NSString * scanLine1 = [NSString stringWithFormat:NSLocalizedString(
				@"%s scanned at %s, %s issued at %s", @"Scrub Menu Entry 1"),
									formatBytes(scrub.scanned).c_str(),
									formatRate(scrub.passScanned, elapsed).c_str(),
									formatBytes(scrub.issued).c_str(),
									formatRate(scrub.passIssued, elapsed).c_str()];
			NSString * scanLine2 = [NSString stringWithFormat:NSLocalizedString(
				@"%s total, %0.2f %% done, %s remaining, %i errors", @"Scrub Menu Entry 2"),
									formatBytes(scrub.total).c_str(),
									100.0*scrub.issued/scrub.total,
									formatTimeRemaining(scrub, elapsed).c_str(),
									scrub.errors];
			[vdevMenu addItemWithTitle:scanLine0 action:nullptr keyEquivalent:@""];
			auto m1 = [vdevMenu addItemWithTitle:scanLine1 action:nullptr keyEquivalent:@""];
			auto m2 = [vdevMenu addItemWithTitle:scanLine2 action:nullptr keyEquivalent:@""];
			m1.indentationLevel = 1;
			m2.indentationLevel = 1;
		}
		for (auto && vdev: vdevs)
		{
			// VDev
			addVdev(pool, vdev, vdevMenu);
			// Children
			auto devices = zfs::vdevChildren(vdev);
			for (auto && device: devices)
			{
				auto item = addVdev(pool, device, vdevMenu);
				[item setIndentationLevel:1];
			}
		}
		// Caches
		auto caches = pool.caches();
		if (caches.size() > 0)
		{
			[vdevMenu addItemWithTitle:@"cache" action:nullptr keyEquivalent:@""];
			for (auto && cache: caches)
			{
				auto item = addVdev(pool, cache, vdevMenu);
				[item setIndentationLevel:1];
			}
		}
		// Filesystems
		[vdevMenu addItem:[NSMenuItem separatorItem]];
		auto childFileSystems = pool.allFileSystems();
		if (childFileSystems.empty())
		{
			// This seems to happen when a pool is UNAVAIL
			NSMenuItem * item = [vdevMenu addItemWithTitle:@"No Filesystems!" action:nil keyEquivalent:@""];
			[item setEnabled:NO];
		}
		else
		{
			for (auto & fs : childFileSystems)
			{
				auto fsLine = formatStatus(fs);
				NSMenuItem * item = [vdevMenu addItemWithTitle:fsLine action:nullptr keyEquivalent:@""];
				item.representedObject = [NSString stringWithUTF8String:fs.name()];
				item.submenu = createFSMenu(fs, delegate);
			}
		}
		// Actions
		NSString * poolName = [NSString stringWithUTF8String:pool.name()];
		NSMenuItem * item = nullptr;
		[vdevMenu addItem:[NSMenuItem separatorItem]];
		item = [vdevMenu addItemWithTitle:@"Export"
								   action:@selector(exportPool:) keyEquivalent:@""];
		item.representedObject = poolName;
		item.target = delegate;
		if (scrub.state == zfs::ScanStat::scanning)
		{
			item = [vdevMenu addItemWithTitle:@"Scrub Stop"
									   action:@selector(scrubStopPool:) keyEquivalent:@""];
			item.representedObject = poolName;
			item.target = delegate;
		}
		else
		{
			item = [vdevMenu addItemWithTitle:@"Scrub"
									   action:@selector(scrubPool:) keyEquivalent:@""];
			item.representedObject = poolName;
			item.target = delegate;
		}
	}
	catch (std::exception const & e)
	{
		[vdevMenu addItemWithTitle:NSLocalizedString(@"Error reading pool configuration", @"Pool Config Error Message")
							action:nullptr keyEquivalent:@""];
	}
	return vdevMenu;
}

- (void)createPoolMenu:(NSMenu*)menu
{
	NSInteger poolMenuIdx = [menu indexOfItemWithTag:ZPoolAnchorMenuTag];
	if (poolMenuIdx < 0)
		return;
	NSInteger poolItemRootIdx = poolMenuIdx + 1;
	NSUInteger poolIdx = 0;
	for (auto && pool: [_watcher pools])
	{
		NSString * poolLine = [NSString stringWithFormat:NSLocalizedString(@"%s (%@)", @"Pool Menu Entry"),
			pool.name(), zfs::emojistring_pool_status_t(pool.status())];
		NSMenuItem * poolItem = [[NSMenuItem alloc] initWithTitle:poolLine action:NULL keyEquivalent:@""];
		NSMenu * vdevMenu = createVdevMenu(pool, self);
		[poolItem setSubmenu:vdevMenu];
		[menu insertItem:poolItem atIndex:poolItemRootIdx + poolIdx];
		[_dynamicMenus addObject:poolItem];
		++poolIdx;
	}
}

- (void)createActionMenu:(NSMenu*)menu
{
	NSInteger actionMenuIdx = [menu indexOfItemWithTag:ActionAnchorMenuTag];
	if (actionMenuIdx < 0)
		return;
	// Unlock
	NSUInteger encryptionRootCount = 0;
	NSMenuItem * unlockItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Load Keys", @"Load Key Menu Entry") action:NULL keyEquivalent:@""];
	NSMenu * unlockMenu = [[NSMenu alloc] init];
	[unlockItem setSubmenu:unlockMenu];
	for (auto && pool: [_watcher pools])
	{
		for (auto & fs : pool.allFileSystems())
		{
			auto [encRoot, isRoot] = fs.encryptionRoot();
			auto keyStatus = fs.keyStatus();
			if (isRoot && keyStatus == zfs::ZFileSystem::unavailable)
			{
				NSString * fsName = [NSString stringWithUTF8String:fs.name()];
				NSMenuItem * item = [unlockMenu addItemWithTitle:fsName
														  action:@selector(loadKey:) keyEquivalent:@""];
				item.representedObject = fsName;
				item.target = self;
				encryptionRootCount++;
			}
		}
	}
	if (encryptionRootCount > 0)
	{
		[menu insertItem:unlockItem atIndex:actionMenuIdx + 1];
		[_dynamicMenus addObject:unlockItem];
	}
}

- (void)clearDynamicMenu:(NSMenu*)menu
{
	for (NSMenuItem * m in _dynamicMenus)
	{
		[menu removeItem:m];
	}
	[_dynamicMenus removeAllObjects];
}

- (void)errorDetectedInPool:(std::string const &)pool
{
	NSUserNotification * notification = [[NSUserNotification alloc] init];
	notification.title = NSLocalizedString(@"ZFS Pool Error", @"ZFS Pool Error Title");
	NSString * errorFormat = NSLocalizedString(@"ZFS detected an error on pool %s.", @"ZFS Pool Error Format");
	notification.informativeText = [NSString stringWithFormat:errorFormat, pool.c_str()];
	notification.hasActionButton = NO;
	[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

- (void)errorDetected:(std::string const &)error
{
	NSUserNotification * notification = [[NSUserNotification alloc] init];
	notification.title = NSLocalizedString(@"ZFS Error", @"ZFS Error Title");
	NSString * errorFormat = NSLocalizedString(@"ZFS encountered an error: %s.", @"ZFS Error Format");
	notification.informativeText = [NSString stringWithFormat:errorFormat, error.c_str()];
	notification.hasActionButton = NO;
	[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

#pragma mark ZFS Maintenance

static NSString * getPassword()
{
	auto param = @{
		(__bridge NSString*)kCFUserNotificationAlertHeaderKey: @"Mount Filesystem with Key",
		(__bridge NSString*)kCFUserNotificationAlertMessageKey: @"Enter the password for mounting encrypted filesystems",
		(__bridge NSString*)kCFUserNotificationDefaultButtonTitleKey: @"Mount",
		(__bridge NSString*)kCFUserNotificationTextFieldTitlesKey: @"Password",
	};
	SInt32 error = 0;
	auto notification = CFUserNotificationCreate(kCFAllocatorDefault, 30,
		kCFUserNotificationPlainAlertLevel | CFUserNotificationSecureTextField(0),
							 &error, (__bridge CFDictionaryRef)param);
	CFOptionFlags response = 0;
	auto ret = CFUserNotificationReceiveResponse(notification, 0, &response);
	if (ret != 0)
	{
		CFRelease(notification);
		return nil;
	}
	auto pass = CFUserNotificationGetResponseValue(notification, kCFUserNotificationTextFieldValuesKey, 0);
	CFRetain(pass);
	CFRelease(notification);
	return (__bridge_transfer NSString*)pass;
}

- (IBAction)importAllPools:(id)sender
{
	[_authorization importPools:@{} withReply:^(NSError * error)
	 {
		 if (error)
			 [self errorFromHelper:error];
	 }];
}

- (IBAction)exportPool:(id)sender
{
	NSDictionary * opts = @{@"pool": [sender representedObject]};
	[_authorization exportPools:opts withReply:^(NSError * error)
	 {
		 if (error)
			 [self errorFromHelper:error];
	 }];
}

- (IBAction)mountAllFilesystems:(id)sender
{
	[_authorization mountFilesystems:@{} withReply:^(NSError * error)
	 {
		 if (error)
			 [self errorFromHelper:error];
	 }];
}

- (IBAction)mountFilesystem:(id)sender
{
	NSDictionary * opts = @{@"filesystem": [sender representedObject]};
	[_authorization mountFilesystems:opts withReply:^(NSError * error)
	 {
		 if (error)
			 [self errorFromHelper:error];
	 }];
}

- (IBAction)unmountFilesystem:(id)sender
{
	NSDictionary * opts = @{@"filesystem": [sender representedObject]};
	[_authorization unmountFilesystems:opts withReply:^(NSError * error)
	 {
		 if (error)
			 [self errorFromHelper:error];
	 }];
}

- (IBAction)loadKey:(id)sender
{
	NSString * fs = [sender representedObject];
	auto pass = getPassword();
	if (!pass)
		return;
	NSDictionary * opts = @{@"filesystem": fs, @"key": pass};
	[_authorization loadKeyForFilesystem:opts withReply:^(NSError * error)
	 {
		 if (error)
			 [self errorFromHelper:error];
	 }];
}

- (IBAction)scrubPool:(id)sender
{
	NSDictionary * opts = @{@"pool": [sender representedObject]};
	[_authorization scrubPool:opts withReply:^(NSError * error)
	 {
		 if (error)
			 [self errorFromHelper:error];
	 }];
}

- (IBAction)scrubStopPool:(id)sender
{
	NSDictionary * opts = @{@"pool": [sender representedObject], @"stop": @YES};
	[_authorization scrubPool:opts withReply:^(NSError * error)
	 {
		 if (error)
			 [self errorFromHelper:error];
	 }];
}

@end
