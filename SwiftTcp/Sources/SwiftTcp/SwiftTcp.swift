import Foundation
import Network

typealias SocketData = [UInt8]
typealias DefaultActionDataParam = (Data) -> Void
@available(macOS 10.14, *)
class SwiftTcpService {
    fileprivate var client : SwiftTcpClient?
    fileprivate var dataActionsFromSync : DefaultActionDataParam?
    
    func setClientIP(hostAddress: String, hostIP: UInt16){
        if(client != nil){
            client = nil // dispose of the client if any
        }
        
        client = SwiftTcpClient(host: hostAddress, port: hostIP)
        client?.onConnect = {
            print("Connected to the server.")
        }
        
        client?.onMessage = { [weak self] data in
            self?.dataActionsFromSync?(data)
            self?.dataActionsFromSync = nil
        }
        
        client?.onDisconnect = { error in
            if let error = error {
                print("Disconnected with error: \(error.localizedDescription)")
            } else {
                print("Disconnected gracefully.")
            }
        }
        
        client?.startLoopTimer() // start looping & ping attempts
    }
    
    func startConnection(){
        client?.connect()
    }
    
    func rebootConnection(){
        client?.reconnect()
    }
    
    func isConnected() -> Bool{
        return client?.isConnected ?? false
    }
    
    func sendPing(){
        client?.sendPing()
    }
    
    func closeConnection(){
        client?.disconnect()
    }
    
    func rebootConnectionIfNeeded(){
        if(!isConnected()){
            rebootConnection()
        }
    }
    
    func cancelAnyPendingRequests(){
        
    }
    
    func sendData(bytes: SocketData, optionalAction: DefaultActionDataParam? = nil){
        dataActionsFromSync = optionalAction
        client?.send(data: Data(bytes))
    }
    func sendDataWithoutResponse(bytes: SocketData){
        client?.send(data: Data(bytes))
    }
    
    func manuallyListenToDataStream(){
        client?.receiveMessage()
    }
}

@available(macOS 10.14, *)
fileprivate final class SwiftTcpClient : @unchecked Sendable {
    // MARK: - Properties
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "SwiftTcp.ConnectionQueue")
    
    public var onConnect: (() -> Void)?
    public var onMessage: ((Data) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?
    
    var isConnected: Bool = false
    var isReconnecting: Bool = false
    var requiresTimerLoop = true
    
    // Configuration
    private let pingMessage = "PING MESSAGE"
    
    private let pongMessage: String = "PONG"
    private let pingInterval: TimeInterval = 10 // Send ping every 10 seconds
    private let pingTimeout: TimeInterval = 5  // Timeout if no pong after 5 seconds
    private var runPing = false
    private var ghost: NWEndpoint.Host?
    private var gport: NWEndpoint.Port?
    private var dataToSendOnConnection : Data?
    
    // MARK: - Initialization
    public init(host: String, port: UInt16) {
        self.ghost = NWEndpoint.Host(host)
        self.gport = NWEndpoint.Port(rawValue: port)!
    }
    
    func startLoopTimer(){
        startTimerRepeating(seconds: pingInterval){ [weak self] in
            guard let self = self else {return false}
            if self.runPing {
                self.sendPing()
            }
            
            return self.requiresTimerLoop
        }
    }
    
    private func startTimerRepeating(seconds: Double, action: @escaping @Sendable () -> Bool) {
        DispatchQueue.main.async {
            let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { timer in
                if !action() {
                    timer.invalidate()
                }
            }

            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    // MARK: - Connect
    public func connect() {
        connection = NWConnection(host: ghost!, port: gport!, using: .tcp)
        connection!.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                isConnected = true
                onConnect?()
                startPing()
                receiveMessage()
                
                if let dataToSend = dataToSendOnConnection{
                    send(data: dataToSend)
                    dataToSendOnConnection = nil
                }
                
            case .failed(let error):
                isConnected = false
                stopPing()
                onDisconnect?(error)
                reconnect()
            case .cancelled:
                isConnected = false
                stopPing()
                onDisconnect?(nil)
            default:
                break
            }
        }
        connection!.start(queue: queue)
    }
    
    // MARK: - Disconnect
    public func disconnect() {
        connection?.cancel()
        isConnected = false
        stopPing()
    }
    
    // MARK: - Reconnect
    func reconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            print("Reconnecting...")
            self?.connection?.cancel()
            self?.connect()
            self?.isReconnecting = false
        }
    }
    
    // MARK: - Send Message
    public func send(data: Data) {
        guard isConnected else {
            print("Cannot send data. Connection is not active.")
            dataToSendOnConnection = data
            
            // set
            return
        }
        
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("Failed to send data: \(error.localizedDescription)")
            } else {
                print("Data sent successfully.")
            }
        })
    }
    
    public func send(message: String) {
        guard let data = message.data(using: .utf8) else {
            print("Failed to encode string as data.")
            return
        }
        send(data: data)
    }
    
    // MARK: - Receive Messages
    func receiveMessage(byteCountMinimum: Int = 1) {
        // a custom min length needs to be set for each operators,
        connection?.receive(minimumIncompleteLength: byteCountMinimum, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {return}
            if let error = error {
                print("Error receiving message: \(error.localizedDescription)")
                disconnect()
                return
            }
            
            if let data = data, !data.isEmpty {
                if let message = String(data: data, encoding: .utf8), message == pongMessage {
                    print("PONG received")
                } else {
                    let response = data.getDataArray()
                    
                    print ("RECEIVED DATA \(response), COUNT \(response.count)")
                    self.onMessage?(data)
                }
            }
            
            if isComplete {
                print("Connection closed by server.")
                disconnect()
            } else {
                receiveMessage(byteCountMinimum: 1) // Re-invoke to listen for the next broadcast
            }
        }
    }
    
    // MARK: - Ping Mechanism
    private func startPing() {
        runPing = true
        
    }
    
    private func stopPing() {
        runPing = false
    }
    
    func sendPing() {
        print("Sending PING")
        send(message: pingMessage)
    }
}


extension Data
{
    func getDataArray() -> SocketData{
        return SocketData(self)
    }
}
