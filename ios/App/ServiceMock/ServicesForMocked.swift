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

// This file is only used in Mocked target. It replaces some services that cannot be
// run in tests and mocked scenarios.

var Services = ServicesSingleton()

class ServicesSingleton {

    fileprivate init() {}

    lazy var persistenceLocal: PersistenceService = LocalStoragePersistenceService()
    lazy var persistenceRemote: PersistenceService = ICloudPersistenceService()
    lazy var persistenceRemoteLegacy: PersistenceService = ICloudPersistenceService()

    lazy var crypto: CryptoServiceIn = CryptoServiceMock()

    lazy var http = HttpClientService()
    lazy var api: BlockaApiServiceIn = BlockaApiService2()
    lazy var apiForCurrentUser = BlockaApiCurrentUserService()

    lazy var privateDns: PrivateDnsService = PrivateDnsServiceImpl()
    lazy var systemNav = SystemNavService()

    lazy var storeKit = StoreKitService()
    lazy var notification = NotificationService()
    lazy var job = JobService()
    lazy var timer = TimerService()

    lazy var dialog = DialogService()

}

func resetServices() {
    Services = ServicesSingleton()
}
