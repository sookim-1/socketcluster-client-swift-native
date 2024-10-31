//
//  AsyncScClient.swift
//  ScClientNative
//
//  Created by sookim on 10/31/24.
//

import Foundation

public class AsyncScClient: Listener {

    var authToken: String?
    var url: URL
    var protocols: [String]
    var socket: URLSessionWebSocketTask?
    var counter: AtomicIntegerActor

    var onConnect: ((AsyncScClient)-> Void)?
    var onConnectError: ((AsyncScClient, Error?)-> Void)?
    var onDisconnect: ((AsyncScClient, Error?)-> Void)?
    var onSetAuthentication: ((AsyncScClient, String?)-> Void)?
    var onAuthentication: ((AsyncScClient, Bool?)-> Void)?

    public init(url: String, authToken: String? = nil, protocols: [String] = []) {
        self.counter = AtomicIntegerActor()
        self.authToken = authToken
        self.url = URL(string: url)!
        self.protocols = protocols
        super.init()
    }

    public func connect() {
        self.socket = URLSession.shared.webSocketTask(with: self.url, protocols: protocols)
        self.socket?.delegate = self
        self.socket?.resume()
    }

    public func isConnected() -> Bool {
        self.socket?.state == .running
    }

    public func disconnect() {
        self.socket?.cancel()
    }

    public func setAuthToken(token: String) {
        self.authToken = token
    }

    public func getAuthToken() -> String? {
        return self.authToken
    }

    public func setBasicListener(onConnect: ((AsyncScClient)-> Void)?, onConnectError: ((AsyncScClient, Error?)-> Void)?, onDisconnect: ((AsyncScClient, Error?)-> Void)?) {
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
        self.onConnectError = onConnectError
    }

    public func setAuthenticationListener (onSetAuthentication: ((AsyncScClient, String?)-> Void)?, onAuthentication: ((AsyncScClient, Bool?)-> Void)?) {
        self.onSetAuthentication = onSetAuthentication
        self.onAuthentication = onAuthentication
    }

}

// MARK: - Event
extension AsyncScClient {

    private func sendHandShake() async throws {
        let handshake = Model.getHandshakeObject(authToken: self.authToken, messageId: await counter.incrementAndGet())

        try await self.socket?.send(.string(handshake.toJSONString()!))
    }

    private func ack(cid: Int) async throws -> AckHandler {
        return  {
            (error: AnyObject?, data: AnyObject?) in
            Task {
                let ackObject = Model.getReceiveEventObject(data: JSONConverter.jsonString(from: data), error: JSONConverter.jsonString(from: error), messageId: cid)
                try await self.socket?.send(.string(ackObject.toJSONString()!))
            }
        }
    }

    public func emit<T: Encodable>(eventName: String, data: T?) async throws {
        let emitObject = Model.getEmitEventObject(eventName: eventName, data: data, messageId: await counter.incrementAndGet())
        try await self.socket?.send(.string(emitObject.toJSONString()!))
    }

    public func emitAck<T: Encodable>(eventName: String, data: T?, ack: @escaping AckEventNameHandler) async throws {
        let id = await counter.incrementAndGet()
        let emitObject = Model.getEmitEventObject(eventName: eventName, data: data, messageId: id)
        putEmitAck(id: id, eventName: eventName, ack: ack)
        try await self.socket?.send(.string(emitObject.toJSONString()!))
    }

    public func subscribe(channelName: String, token: String? = nil) async throws {
        let subscribeObject = Model.getSubscribeEventObject(channelName: channelName, messageId: await counter.incrementAndGet(), token : token)
        try await self.socket?.send(.string(subscribeObject.toJSONString()!))
    }

    public func subscribeAck(channelName: String, token: String? = nil, ack: @escaping AckEventNameHandler) async throws {
        let id = await counter.incrementAndGet()
        let subscribeObject = Model.getSubscribeEventObject(channelName: channelName, messageId: id, token: token)
        putEmitAck(id: id, eventName: channelName, ack: ack)
        try await self.socket?.send(.string(subscribeObject.toJSONString()!))
    }

    public func unsubscribe(channelName: String) async throws {
        let unsubscribeObject = Model.getUnsubscribeEventObject(channelName: channelName, messageId: await counter.incrementAndGet())
        try await self.socket?.send(.string(unsubscribeObject.toJSONString()!))
    }

    public func unsubscribeAck(channelName: String, ack: @escaping AckEventNameHandler) async throws {
        let id = await counter.incrementAndGet()
        let unsubscribeObject = Model.getUnsubscribeEventObject(channelName: channelName, messageId: id)
        putEmitAck(id: id, eventName: channelName, ack: ack)
        try await self.socket?.send(.string(unsubscribeObject.toJSONString()!))
    }

    public func publish<T: Encodable>(channelName: String, data: T?) async throws {
        let publishObject = Model.getPublishEventObject(channelName: channelName, data: data, messageId: await counter.incrementAndGet())
        try await self.socket?.send(.string(publishObject.toJSONString()!))
    }

    public func publishAck<T: Encodable>(channelName: String, data: T?, ack: @escaping AckEventNameHandler) async throws {
        let id = await counter.incrementAndGet()
        let publishObject = Model.getPublishEventObject(channelName: channelName, data: data, messageId: id)
        putEmitAck(id: id, eventName: channelName, ack: ack)
        try await self.socket?.send(.string(publishObject.toJSONString()!))
    }

    public func onChannel(channelName: String, ack: @escaping OnEventHandler) {
        putOnListener(eventName: channelName, onListener: ack)
    }

    public func on(eventName: String, ack: @escaping OnEventHandler) {
        putOnListener(eventName: eventName, onListener: ack)
    }

    public func onAck(eventName: String, ack: @escaping AckOnEventHandler) {
        putOnAckListener(eventName: eventName, onAckListener: ack)
    }

    public func sendPing(completionHandler: @escaping (Error?) -> Void) {
        self.socket?.sendPing(pongReceiveHandler: completionHandler)
    }

    public func sendEmptyDataEvent() async throws {
        try await self.socket?.send(.data(Data()))
    }

    public func sendEmptyStringEvent() async throws {
        try await self.socket?.send(.string(""))
    }

    func receive() -> AsyncThrowingStream<Void, Error> {
        AsyncThrowingStream { [weak self] in
            guard let self
            else { return }

            let message: () = try await self.receiveSingleMessage()

            return Task.isCancelled ? nil : message
        }
    }

    private func receiveSingleMessage() async throws {
        let receiveData = try await socket?.receive()

        switch receiveData {
        case .data(let data):
            self.websocketDidReceiveData(data: data)
        case .string(let string):
            try await self.websocketDidReceiveMessage(text: string)
        default:
            self.socket?.cancel(with: .unsupportedData, reason: nil)
            throw AsyncScClientError.decodingError
        }
    }

    public func websocketDidReceiveMessage(text: String) async throws {
        if let messageObject = JSONConverter.deserializeString(message: text),
           let (data, rid, cid, eventName, error) = Parser.getMessageDetails(myMessage: messageObject) {

            let parseResult = Parser.parse(rid: rid, cid: cid, event: eventName)

            switch parseResult {
            case .isAuthenticated:
                let isAuthenticated = ClientUtils.getIsAuthenticated(message: messageObject)
                onAuthentication?(self, isAuthenticated)
            case .publish:
                guard let dictionary = data as? [String: Any],
                      let channelName = dictionary["channel"] as? String,
                      let channelData = dictionary["data"] as? String,
                      let model = Model.getChannelObject(channelName: channelName, data: channelData)
                else { return }

                self.handleOnListener(eventName: model.channel, data: model.data as AnyObject)
            case .removeToken:
                self.authToken = nil
            case .setToken:
                authToken = ClientUtils.getAuthToken(message: messageObject)
                self.onSetAuthentication?(self, authToken)
            case .ackReceive:
                handleEmitAck(id: rid!, error: error as AnyObject, data: data as AnyObject)
            case .event:
                if hasEventAck(eventName: eventName!) {
                    handleOnAckListener(eventName: eventName!, data: data as AnyObject, ack: try await self.ack(cid: cid!))
                } else {
                    handleOnListener(eventName: eventName!, data: data as AnyObject)
                }
            }
        }
    }

    public func websocketDidReceiveData(data: Data) {
        print("Received data: \(data.count)")
    }

}

// MARK: - URLSessionWebSocketDelegate
extension AsyncScClient: URLSessionWebSocketDelegate {

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task {
            await counter.setValue(0)
            try await self.sendHandShake()
            self.receive()
            self.onConnect?(self)
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.onDisconnect?(self, WebSocketError.findMatchError(closeCode: closeCode.rawValue))
    }

}