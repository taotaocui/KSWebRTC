//
//  WebSocketServer.swift
//  KSMessageServer
//
//  Created by saeipi on 2020/9/26.
//  Copyright © 2020 saeipi. All rights reserved.
//

import Foundation
import Network

final class WebSocketServer {
    
    //global线程
    private let queue = DispatchQueue.global()
    //端口
    private let port: NWEndpoint.Port = 6080
    //网络监听者
    private let listener: NWListener
    //用Set来存放连接进来的客户端对象
    private var connectedClients = Set<WebSocketClient>()
    
    // MARK:- 初始化后台服务
    init() throws {
        let parameters = NWParameters.tcp//TCP连接方式
        let webSocketOptions = NWProtocolWebSocket.Options()//连接属性设置
        webSocketOptions.autoReplyPing = true//自动回复ping包
        parameters.defaultProtocolStack.applicationProtocols.append(webSocketOptions)
        self.listener = try NWListener(using: parameters, on: self.port)//设置连接相关的方式和参数
    }
    
    // MARK:- 开启后台服务
    func start() {
        //设置接收到消息的处理方法
        self.listener.newConnectionHandler = self.newConnectionHandler
        //开启后台服务监听
        self.listener.start(queue: queue)
        print("消息服务器开始监听端口 \(self.port)")
    }
    
    // MARK:- 接收到一个新的client的处理方法
    private func newConnectionHandler(_ connection: NWConnection) {
        let client = WebSocketClient(connection: connection)//新建一个客户端对象
        self.connectedClients.insert(client)//往set里面插入一个客户端对象
        client.connection.start(queue: self.queue)//开始连接这个客户端
        //接收到这个客户端的数据
        client.connection.receiveMessage { [weak self] (data, context, isComplete, error) in
            //数据处理
            self?.didReceiveMessage(from: client, data: data, context: context, error: error)
        }
        print("有一个客户端连进来了， 现在连接的客户端总数: \(self.connectedClients.count)")
    }
    // MARK:- 断开一个client
    private func didDisconnect(client: WebSocketClient) {
        self.connectedClients.remove(client)
        print("有一个客户端断开了， 现在连接的客户端总数: \(self.connectedClients.count)")

    }
    
    // MARK:- 收到来自client的信息 处理数据
    private func didReceiveMessage(from client: WebSocketClient,
                                   data: Data?,
                                   context: NWConnection.ContentContext?,
                                   error: NWError?) {
        
        if let context = context, context.isFinal {//如果是收到终止连接的context信息
            client.connection.cancel()//取消连接
            self.didDisconnect(client: client)//断开连接
            return
        }
        
        //如果收到data数据, 分发给其他client
        if let data = data {
            var message: [String : Any]?
            do {
                message = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String : Any]
            } catch {
            }
            
            guard var _message = message else { return }
            if (_message["register"] as? String) != nil {
                //客户端连接成功后进行注册
                client.user_id   = (_message["user_id"] as? Int) ?? 0
                client.user_name = (_message["user_name"] as? String) ?? ""
                var users:[[String : Any]] = [[String : Any]]()
                for item in self.connectedClients {
                    let user = ["user_id":item.user_id,"user_name":item.user_name] as [String : Any]
                    users.append(user);
                }
                _message["users"] = users;
            }
            var relay: Int = 0;
            if let _relay  = _message["relay"] as? Int {
                relay = _relay;
            }
            
            if relay == 1 {//广播（自己当前客户端）
                let otherClients = self.connectedClients.filter { $0 != client }//能用这个语法是因为实现了equal协议
                //把这个客户端发过来的数据转发给其他client
                self.broadcast(data: data, to: otherClients)
            }
            else if relay == 2 {//指定转发
                if let user_id = _message["target"] as? Int {
                    let targets = self.connectedClients.filter { $0.user_id == user_id }
                    self.broadcast(data: data, to: targets)
                }
            }
            else if relay == 3 {//全部
                if let msg_data = try? JSONSerialization.data(withJSONObject: _message, options: []) {
                    self.broadcast(data: msg_data, to: self.connectedClients)
                }
            }
        }
        //继续接收消息
        client.connection.receiveMessage { [weak self] (data, context, isComplete, error) in
            self?.didReceiveMessage(from: client, data: data, context: context, error: error)
        }
    }
    
    private func dictToData(dict:[String : Any]) -> Data? {
        let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
        return data
    }
    
    // MARK:- 发送数据给其他client
    private func broadcast(data: Data, to clients: Set<WebSocketClient>) {
        clients.forEach {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)//元数据
            let context = NWConnection.ContentContext(identifier: "context", metadata: [metadata])
            //发送数据
            $0.connection.send(content: data,
                               contentContext: context,
                               isComplete: true,
                               completion: .contentProcessed({ _ in }))
        }
    }
}
