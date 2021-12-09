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
import UIKit

class AccountRepo {

    var accountHot: AnyPublisher<AccountWithKeypair, Never> {
        self.writeAccount.compactMap { $0 }.eraseToAnyPublisher()
    }

    var accountIdHot: AnyPublisher<AccountId, Never> {
        self.accountHot.map { it in it.account.id }.removeDuplicates().eraseToAnyPublisher()
    }

    private lazy var local = Services.persistenceLocal
    private lazy var remote = Services.persistenceRemote
    private lazy var remoteLegacy = Services.persistenceRemoteLegacy
    private lazy var crypto = Services.crypto
    private lazy var api = Services.api

    private lazy var processingRepo = Repos.processingRepo
    private lazy var enteredForegroundHot = Repos.foregroundRepo.enteredForegroundHot

    private let decoder = blockaDecoder
    private let encoder = blockaEncoder

    private let bgQueue = DispatchQueue(label: "AccRepoBgQueue")

    fileprivate let writeAccount = CurrentValueSubject<AccountWithKeypair?, Never>(nil)

    fileprivate let proposeAccountRequests = PassthroughSubject<Account, Never>()
    fileprivate let refreshAccountRequests = PassthroughSubject<AccountId, Never>()
    fileprivate let restoreAccountRequests = PassthroughSubject<AccountId, Never>()

    private let recentAccount = Atomic<AccountWithKeypair?>(nil)
    private let lastAccountRequestTimestamp = Atomic<Double>(0)

    private let ACCOUNT_REFRESH_SEC: Double = 10 * 60 // Same as on Android

    // Subscribers with lifetime same as the repository
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadFromPersistenceOrCreateAccount()
        listenToProposeAccountRequests()
        listenToRefreshAccountRequests()
        listenToRestoreAccountRequests()
        listenToAccountPublisherAndCacheLocally()
        refreshAccountPeriodically()
    }
    
    // Gets account from API based on user entered account ID. Does sanitization.
    func restoreAccount(_ newAccountId: AccountId) {
        processingRepo.notify(self, ongoing: true)
        restoreAccountRequests.send(newAccountId)
    }

    // Accepts account received from the payment callback (usually old receipt).
    func proposeAccount(_ newAccount: Account) {
        processingRepo.notify(self, ongoing: true)
        proposeAccountRequests.send(newAccount)
    }

    // A cold publisher alternative to get the current account
    func getAccount() -> AnyPublisher<AccountWithKeypair, Error> {
        guard let account = recentAccount.value else {
            return Fail(error: "getAccount: account not available yet").eraseToAnyPublisher()
        }
        return Just(account).setFailureType(to: Error.self).eraseToAnyPublisher()
    }

    private func loadFromPersistenceOrCreateAccount() {
        self.processingRepo.notify(self, ongoing: true)
        Publishers.CombineLatest(
            self.loadAccountFromPersistence(),
            self.loadKeypairFromPersistence()
        )
        .tryMap { it in
            try self.validateAccount(it.0, it.1)
            return AccountWithKeypair(account: it.0, keypair: it.1)
        }
        .tryCatch { err -> AnyPublisher<AccountWithKeypair, Error> in
            // TODO: create new user on any error?
            if err as? CommonError == CommonError.emptyResult {
                return self.createNewUser()
            }
            throw err
        }
        .flatMap { it in
            Publishers.CombineLatest(
                self.saveAccountToPersistence(it.account),
                self.saveKeypairToPersistence(it.keypair)
            )
            .tryMap { _ in it }
        }
        .sink(
            onValue: { it in
                self.processingRepo.notify(self, ongoing: false)
                self.writeAccount.send(it)
            },
            onFailure: { err in self.processingRepo.notify(self, err, major: false) }
        )
        .store(in: &cancellables)
    }

    // Receives Account object to be verified and saved. No request, but may regen keys.
    func listenToProposeAccountRequests() {
        proposeAccountRequests
        .debounce(for: .seconds(DEFAULT_USER_INTERACTION_DEBOUNCE), scheduler: bgQueue)
        //.removeDuplicates()
        .map { it in (it, self.recentAccount.value) }
        .tryMap { it -> (Account, AccountWithKeypair?) in
            try self.validateAccountId(it.0.id)
            return it
        }
        .flatMap { it -> AnyPublisher<(Account, Keypair), Error> in
            let accountPublisher: AnyPublisher<Account, Error> = Just(it.0)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
            var keypairPublisher: AnyPublisher<Keypair, Error> = self.crypto.generateKeypair()

            if let acc = it.1, acc.account.id == it.0.id {
                // Use same keypair if account ID hasn't changed
                keypairPublisher = Just(acc.keypair)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }

            return Publishers.CombineLatest(
                accountPublisher,
                keypairPublisher
            )
            .eraseToAnyPublisher()
        }
        .tryMap { it -> AccountWithKeypair in
            try self.validateAccount(it.0, it.1)
            return AccountWithKeypair(account: it.0, keypair: it.1)
        }
        .flatMap { it in
            Publishers.CombineLatest(
                self.saveAccountToPersistence(it.account),
                self.saveKeypairToPersistence(it.keypair)
            )
            .tryMap { _ in it }
        }
        .sink(
            onValue: { it in
                self.processingRepo.notify(self, ongoing: false)
                self.writeAccount.send(it)
            },
            onFailure: { err in self.processingRepo.notify(self, err, major: true) }
        )
        .store(in: &cancellables)
    }

    // Account ID is sanitised and validated, do the request and update Account model
    func listenToRefreshAccountRequests() {
        refreshAccountRequests
        .flatMap { accountId in
            self.api.getAccount(id: accountId)
        }
        .sink(
            onValue: { it in
                self.lastAccountRequestTimestamp.value = Date().timeIntervalSince1970
                self.proposeAccountRequests.send(it)
            },
            onFailure: { err in self.processingRepo.notify(self, err, major: false) }
        )
        .store(in: &cancellables)
    }

    // Account ID is input from user, sanitize it and then forward to do the refresh
    func listenToRestoreAccountRequests() {
        restoreAccountRequests
        .debounce(for: .seconds(DEFAULT_USER_INTERACTION_DEBOUNCE), scheduler: bgQueue)
        .removeDuplicates()
        .map { accountId in accountId.lowercased().trimmingCharacters(in: CharacterSet.whitespaces) }
        .tryMap { accountId in
            try self.validateAccountId(accountId)
            return accountId
        }
        .sink(
            onValue: { it in self.refreshAccountRequests.send(it) },
            onFailure: { err in self.processingRepo.notify(self, err, major: true) }
        )
        .store(in: &cancellables)
    }

    // When app enters foreground, periodically refresh account
    private func refreshAccountPeriodically() {
        enteredForegroundHot
        .filter { it in
            self.lastAccountRequestTimestamp.value < Date().timeIntervalSince1970 - self.ACCOUNT_REFRESH_SEC
        }
        .compactMap { it in self.recentAccount.value }
        .sink(
            onValue: { it in
                self.lastAccountRequestTimestamp.value = Date().timeIntervalSince1970
                self.processingRepo.notify(self, ongoing: true)
                self.refreshAccountRequests.send(it.account.id)
            }
        )
        .store(in: &cancellables)
    }

    private func createNewUser() -> AnyPublisher<AccountWithKeypair, Error> {
        return Publishers.CombineLatest(
            self.api.postNewAccount(),
            self.crypto.generateKeypair()
        )
        .tryMap { it in
            try self.validateAccount(it.0, it.1)
            return AccountWithKeypair(account: it.0, keypair: it.1)
        }
        .eraseToAnyPublisher()
    }

    private func validateAccount(_ account: Account, _ keypair: Keypair) throws {
        try validateAccountId(account.id)
        if keypair.privateKey.isEmpty || keypair.publicKey.isEmpty {
            throw "account with empty keypair"
        }
    }

    private func validateAccountId(_ accountId: AccountId) throws {
        if accountId.isEmpty {
            throw "account with empty ID"
        }
    }

    private func saveAccountToPersistence(_ account: Account) -> AnyPublisher<Void, Error> {
        Just(account).encode(encoder: self.encoder)
        .tryMap { it -> String in
            guard let it = String(data: it, encoding: .utf8) else {
                throw "account: could not encode json data to string"
            }
            return it
        }
        .flatMap { it in
            return self.remote.setString(it, forKey: "account")
        }
        .eraseToAnyPublisher()
    }

    private func saveKeypairToPersistence(_ keypair: Keypair) -> AnyPublisher<Void, Error> {
        Just(keypair).encode(encoder: self.encoder)
        .tryMap { it -> String in
            guard let it = String(data: it, encoding: .utf8) else {
                throw "keypair: could not encode json data to string"
            }
            return it
        }
        .flatMap { it in
            return self.remote.setString(it, forKey: "keypair")
        }
        .eraseToAnyPublisher()
    }

    private func loadAccountFromPersistence() -> AnyPublisher<Account, Error> {
        return remote.getString(forKey: "account").tryCatch { err -> AnyPublisher<String, Error> in
            // A legacy read of the account - to be removed later
            return self.remoteLegacy.getString(forKey: "account")
        }
        .tryMap { it -> Data in
            guard let it = it.data(using: .utf8) else {
                throw "account: failed reading persisted account data"
            }

            return it
        }
        .decode(type: Account.self, decoder: self.decoder)
        .eraseToAnyPublisher()
    }

    private func loadKeypairFromPersistence() -> AnyPublisher<Keypair, Error> {
        return local.getString(forKey: "keypair").tryMap { it -> Data in
            guard let it = it.data(using: .utf8) else {
                throw "keypair: failed reading persisted keypair data"
            }

            return it
        }
        .decode(type: Keypair.self, decoder: self.decoder)
        .tryCatch { err -> AnyPublisher<Keypair, Error> in
            // A legacy read of the keys - to be removed later
            return Publishers.CombineLatest(
                self.local.getString(forKey: "privateKey"),
                self.local.getString(forKey: "publicKey")
            )
            .tryMap { it in
                return Keypair(privateKey: it.0, publicKey: it.1)
            }
            .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }

    // Take account from hot publisher to use in cold publishers (Combine has poor support for this)
    private func listenToAccountPublisherAndCacheLocally() {
        self.accountHot.sink(
            onValue: { it in self.recentAccount.value = it }
        )
        .store(in: &cancellables)
    }

}

class DebugAccountRepo: AccountRepo {

    private let log = Logger("AccRepo")
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()

        accountHot.sink(
            onValue: { it in self.log.v("Account: \(it)") }
        )
        .store(in: &cancellables)

        proposeAccountRequests.sink(
            onValue: { it in self.log.v("ProposeAccountRequest: \(it)") }
        )
        .store(in: &cancellables)

        refreshAccountRequests.sink(
            onValue: { it in self.log.v("RefreshAccountRequest: \(it)") }
        )
        .store(in: &cancellables)

        restoreAccountRequests.sink(
            onValue: { it in self.log.v("RestoreAccountRequest: \(it)") }
        )
        .store(in: &cancellables)
    }
}