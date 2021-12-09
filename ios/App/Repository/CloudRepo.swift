//
//  This file is part of Blokada.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Copyright © 2021 Blocka AB. All rights reserved.
//
//  @author Karol Gusak
//

import Foundation
import Combine

class CloudRepo {

    // Whether DNS profile is currently selected or not, refreshed on foreground
    var dnsProfileActivatedHot: AnyPublisher<CloudDnsProfileActivated, Never> {
        self.writeDnsProfileActivated.compactMap { $0 }.removeDuplicates().eraseToAnyPublisher()
    }

    // The latest device info from our backend, including blocklists, device tag, etc
    var deviceInfoHot: AnyPublisher<DevicePayload, Never> {
        self.writeDeviceInfo.compactMap { $0 }.eraseToAnyPublisher()
    }

    // Lastest device tag info from backend. Used for Cloud DNS profile and Plus VPN
    var deviceTagHot: AnyPublisher<CloudDeviceTag, Never> {
        self.deviceInfoHot.map { it in it.device_tag }.removeDuplicates().eraseToAnyPublisher()
    }

    // Latest user blocklists choice (only backend IDs, needs to be translated client side)
    var blocklistsHot: AnyPublisher<CloudBlocklists, Never> {
        self.deviceInfoHot.map { it in it.lists }.removeDuplicates().eraseToAnyPublisher()
    }
    
    // User selected activity retention (may be empty for "no retention")
    var activityRetentionHot: AnyPublisher<CloudActivityRetention, Never> {
        self.deviceInfoHot.map { it in it.retention }.removeDuplicates().eraseToAnyPublisher()
    }

    // Whether user has currently paused adblocking or not
    var adblockingPausedHot: AnyPublisher<Bool, Never> {
        self.deviceInfoHot.map { it in it.paused }.removeDuplicates().eraseToAnyPublisher()
    }

    private lazy var api = Services.apiForCurrentUser
    private lazy var privateDns = Services.privateDns

    private lazy var envRepo = Repos.envRepo
    private lazy var processingRepo = Repos.processingRepo
    private lazy var enteredForegroundHot = Repos.foregroundRepo.enteredForegroundHot
    private lazy var activeTabHot = Repos.navRepo.activeTabHot
    private lazy var accountIdHot = Repos.accountRepo.accountIdHot

    private let bgQueue = DispatchQueue(label: "CloudRepoBgQueue")

    fileprivate let writeDnsProfileActivated = CurrentValueSubject<CloudDnsProfileActivated?, Never>(nil)
    fileprivate let writeDeviceInfo = CurrentValueSubject<DevicePayload?, Never>(nil)

    fileprivate let requestsSetActivityRetention = PassthroughSubject<CloudActivityRetention, Never>()
    fileprivate let requestsRefreshDeviceInfo = PassthroughSubject<Void, Never>()

    // Subscribers with lifetime same as the repository
    private var cancellables = Set<AnyCancellable>()

    init() {
        onRefreshDeviceInfo()
        onSetActivityRetention()
        onForegroundCheckDnsProfileActivation()
        onTabChangeRefreshDeviceInfo()
        onDeviceTagChangeUpdateDnsProfile()
        onAccountIdChangeRefreshDeviceInfo()
    }

    func setActivityRetention(_ retention: CloudActivityRetention) {
        self.processingRepo.notify(self, ongoing: true)
        requestsSetActivityRetention.send(retention)
    }

    private func onRefreshDeviceInfo() {
        requestsRefreshDeviceInfo
        .debounce(for: .seconds(3), scheduler: bgQueue)
        .flatMap { _ in self.api.getDeviceForCurrentUser() }
        .sink(
            onValue: { it in
                self.processingRepo.notify(self, ongoing: false)
                self.writeDeviceInfo.send(it)
            },
            onFailure: { err in self.processingRepo.notify(self, err, major: true) }
        )
        .store(in: &cancellables)
    }
    
    private func onSetActivityRetention() {
        requestsSetActivityRetention
        .debounce(for: .seconds(DEFAULT_USER_INTERACTION_DEBOUNCE), scheduler: bgQueue)
        .flatMap { it in self.api.putActivityRetentionForCurrentUser(it) }
        .sink(
            onFailure: { err in self.processingRepo.notify(self, err, major: false) },
            onFinished: { self.requestsRefreshDeviceInfo.send() }
        )
        .store(in: &cancellables)
    }


    // Will check the activation status on every foreground event
    private func onForegroundCheckDnsProfileActivation() {
        enteredForegroundHot
        .flatMap { _ in self.privateDns.isPrivateDnsProfileActive() }
        .sink(
            onValue: { isActivated in self.writeDnsProfileActivated.send(isActivated) }
        )
        .store(in: &cancellables)
    }

    // Will recheck device info on each tab change.
    // This struct contains something important for each tab.
    // Entering foreground will also re-publish active tab even if user doesn't change it.
    private func onTabChangeRefreshDeviceInfo() {
        activeTabHot
        .sink(onValue: { it in
            self.processingRepo.notify(self, ongoing: true)
            self.requestsRefreshDeviceInfo.send()
        })
        .store(in: &cancellables)
    }

    // Whenever device tag from backend changes, update the DNS profile in system settings.
    // User is meant to activate it manually, but our app can update it anytime.
    private func onDeviceTagChangeUpdateDnsProfile() {
        deviceTagHot
        .flatMap { it in self.privateDns.savePrivateDnsProfile(tag: it, name: self.envRepo.deviceName) }
        .sink(
            onFailure: { err in self.processingRepo.notify(self, err, major: true) }
        )
        .store(in: &cancellables)
    }

    // Whenever account ID is changed, device tag will change, among other things.
    func onAccountIdChangeRefreshDeviceInfo() {
        accountIdHot
        .sink(onValue: { it in
            self.processingRepo.notify(self, ongoing: true)
            self.requestsRefreshDeviceInfo.send()
        })
        .store(in: &cancellables)
    }

}

class DebugCloudRepo: CloudRepo {

    private let log = Logger("Cloud")
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()

        dnsProfileActivatedHot.sink(
            onValue: { it in self.log.v("dnsProfileActivated: \(it)") }
        )
        .store(in: &cancellables)

        deviceInfoHot.sink(
            onValue: { it in self.log.v("deviceInfo: \(it)") }
        )
        .store(in: &cancellables)

        requestsRefreshDeviceInfo.sink(
            onValue: { it in self.log.v("RefreshDeviceInfo: queued")}
        )
        .store(in: &cancellables)
    }
}
