//
//  DeviceRequest.swift
//  BluetoothLinux
//
//  Created by Alsey Coleman Miller on 1/3/16.
//  Copyright © 2016 PureSwift. All rights reserved.
//

#if os(Linux)
    import Glibc
#elseif os(OSX) || os(iOS)
    import Darwin.C
#endif

import SwiftFoundation

public extension Adapter {

    /// Sends a command to the device and waits for a response.
    
    @inline(__always)
    func deviceRequest<CP: HCICommandParameter, EP: HCIEventParameter>(commandParameter: CP, eventParameterType: EP.Type, timeout: Int = 1000) throws -> EP {
        
        let command = CP.command
        
        let opcodeGroupField = command.dynamicType.opcodeGroupField
        
        let parameterData = commandParameter.byteValue
        
        let data = try HCISendRequest(internalSocket, opcode: (command.rawValue, opcodeGroupField.rawValue), commandParameterData: parameterData, eventParameterLength: EP.length, event: EP.event.rawValue, timeout: timeout)
        
        guard let eventParameter = EP(byteValue: data)
            else { throw AdapterError.GarbageResponse(Data(byteValue: data)) }
        
        return eventParameter
    }
    
    @inline(__always)
    func deviceRequest<C: HCICommand, EP: HCIEventParameter>(command: C, eventParameterType: EP.Type, verifyStatusByte: Bool = true, timeout: Int = 1000) throws -> EP {
        
        let opcode = (command.rawValue, C.opcodeGroupField.rawValue)
        
        let event = EP.event.rawValue
        
        let data = try HCISendRequest(internalSocket, opcode: opcode, event: event, eventParameterLength: EP.length, timeout: timeout)
        
        guard let eventParameter = EP(byteValue: data)
            else { throw AdapterError.GarbageResponse(Data(byteValue: data)) }
        
        return eventParameter
    }
    
    @inline(__always)
    func deviceRequest<CP: HCICommandParameter, E: HCIEvent>(commandParameter: CP, event: E, verifyStatusByte: Bool = true, timeout: Int = 1000) throws {
        
        let command = CP.command
        
        let opcode = (command.rawValue, command.dynamicType.opcodeGroupField.rawValue)
        
        let parameterData = commandParameter.byteValue
        
        let eventParameterLength = verifyStatusByte ? 1 : 0
        
        let data = try HCISendRequest(internalSocket, opcode: opcode, commandParameterData: parameterData, event: event.rawValue, eventParameterLength: eventParameterLength, timeout: timeout)
        
        if verifyStatusByte {
            
            guard let statusByte = data.first
                else { fatalError("Missing status byte!") }
            
            guard statusByte == 0x00
                else { throw AdapterError.DeviceRequestStatus(statusByte) }
        }
    }
    
    @inline(__always)
    func deviceRequest<C: HCICommand, E: HCIEvent>(command: C, event: E, verifyStatusByte: Bool = true, timeout: Int = 1000) throws {
        
        let opcode = (command.rawValue, C.opcodeGroupField.rawValue)
        
        let eventParameterLength = verifyStatusByte ? 1 : 0
        
        let data = try HCISendRequest(internalSocket, opcode: opcode, event: event.rawValue, eventParameterLength: eventParameterLength, timeout: timeout)
        
        if verifyStatusByte {
            
            guard let statusByte = data.first
                else { fatalError("Missing status byte!") }
            
            guard statusByte == 0x00
                else { throw AdapterError.DeviceRequestStatus(statusByte) }
        }
    }
}

// MARK: - Internal HCI Functions

/// int hci_send_req(int dd, struct hci_request *r, int to)
/// Returns event parameter data.
internal func HCISendRequest(deviceDescriptor: CInt, opcode: (commandField: UInt16, groupField: UInt16), commandParameterData: [UInt8] = [], event: UInt8 = 0, eventParameterLength: Int = 0, timeout: Int = 0) throws -> [UInt8] {
    
    // assertions
    assert(timeout >= 0, "Negative timeout value")
    assert(timeout <= Int(Int32.max), "Timeout > Int32.max")
    
    // initialize variables
    var timeout = timeout
    let opcodePacked = HCICommandOpcodePack(opcode.commandField, opcode.groupField).littleEndian
    var eventBuffer = [UInt8](count: HCI.MaximumEventSize, repeatedValue: 0)
    var oldFilter = HCIFilter()
    var newFilter = HCIFilter()
    let oldFilterPointer = withUnsafeMutablePointer(&oldFilter) { UnsafeMutablePointer<Void>($0) }
    let newFilterPointer = withUnsafeMutablePointer(&oldFilter) { UnsafeMutablePointer<Void>($0) }
    var filterLength = socklen_t(sizeof(HCIFilter))
    
    // get old filter
    guard getsockopt(deviceDescriptor, SOL_HCI, HCISocketOption.Filter.rawValue, oldFilterPointer, &filterLength) == 0
        else { throw POSIXError.fromErrorNumber! }
    
    // configure new filter
    newFilter.setPacketType(.Event)
    newFilter.setEvent(HCIGeneralEvent.CommandStatus.rawValue)
    newFilter.setEvent(HCIGeneralEvent.CommandComplete.rawValue)
    newFilter.setEvent(HCIGeneralEvent.LowEnergyMeta.rawValue)
    newFilter.setEvent(event)
    newFilter.opcode = opcodePacked
    
    // set new filter
    guard setsockopt(deviceDescriptor, SOL_HCI, HCISocketOption.Filter.rawValue, newFilterPointer, filterLength) == 0
        else { throw POSIXError.fromErrorNumber! }
    
    // restore old filter in case of error
    func restoreFilter(error: ErrorType) -> ErrorType {
        
        guard setsockopt(deviceDescriptor, SOL_HCI, HCISocketOption.Filter.rawValue, newFilterPointer, filterLength) == 0
            else { return AdapterError.CouldNotRestoreFilter(error, POSIXError.fromErrorNumber!) }
        
        return error
    }
    
    // send command
    do { try HCISendCommand(deviceDescriptor, opcode: opcode, parameterData: commandParameterData) }
    catch { throw restoreFilter(error) }
    
    // retrieve data...
    
    var attempts = 10
    
    while attempts > 0 {
        
        // decrement attempts
        attempts -= 1
        
        // wait for timeout
        if timeout > 0 {
            
            var timeoutPoll = pollfd(fd: deviceDescriptor, events: Int16(POLLIN), revents: 0)
            var pollStatus: CInt = 0
            
            func doPoll() { pollStatus = poll(&timeoutPoll, 1, CInt(timeout)) }
            
            doPoll()
            
            while pollStatus < 0 {
                
                // ignore these errors
                if (errno == EAGAIN || errno == EINTR) {
                    
                    // try again
                    doPoll()
                    continue
                    
                } else {
                    
                    // attempt to restore filter and throw
                    throw restoreFilter(POSIXError.fromErrorNumber!)
                }
            }
            
            // poll timed out
            guard pollStatus != 0
                else { throw restoreFilter(POSIXError(rawValue: ETIMEDOUT)!) }
            
            // decrement timeout (why?)
            timeout -= 10
            
            // make sure its not a negative number
            if timeout < 0 {
                
                timeout = 0
            }
        }
        
        var actualBytesRead = 0
        
        func doRead() { actualBytesRead = read(deviceDescriptor, &eventBuffer, eventBuffer.count) }
        
        doRead()
        
        while actualBytesRead < 0 {
            
            // ignore these errors
            if (errno == EAGAIN || errno == EINTR) {
                
                // try again
                doRead()
                continue
                
            } else {
                
                // attempt to restore filter and throw
                throw restoreFilter(POSIXError.fromErrorNumber!)
            }
        }
        
        let headerData = Array(eventBuffer[1 ..< HCIEventHeader.length])
        let eventData = Array(eventBuffer[(1 + HCIEventHeader.length) ..< actualBytesRead])
        //var length = actualBytesRead - (1 + HCIEventHeader.length)
        
        guard let eventHeader = HCIEventHeader(byteValue: headerData)
            else { throw restoreFilter(AdapterError.GarbageResponse(Data(byteValue: eventBuffer))) }
        
        /// restores the old filter option before exiting
        func done() throws {
            
            guard setsockopt(deviceDescriptor, SOL_HCI, HCISocketOption.Filter.rawValue, newFilterPointer, filterLength) == 0
                else { throw POSIXError.fromErrorNumber! }
        }
        
        switch eventHeader.event {
            
        case HCIGeneralEvent.CommandStatus.rawValue:
            
            guard let parameter = HCIGeneralEvent.CommandStatusParameter(byteValue: eventData)
                else { throw AdapterError.GarbageResponse(Data(byteValue: eventBuffer)) }
            
            /// must be command status for sent command
            guard parameter.opcode == opcodePacked else { continue }
            
            ///
            guard event == HCIGeneralEvent.CommandStatus.rawValue else {
                
                guard parameter.status == 0
                    else { throw restoreFilter(POSIXError(rawValue: EIO)!) }
                
                break
            }
            
            // success!
            try done()
            let dataLength = min(eventData.count, eventParameterLength)
            return  Array(eventData.suffix(dataLength))
            
        case HCIGeneralEvent.CommandComplete.rawValue:
            
            guard let parameter = HCIGeneralEvent.CommandCompleteParameter(byteValue: eventData)
                else { throw AdapterError.GarbageResponse(Data(byteValue: eventBuffer)) }
            
            guard parameter.opcode == opcodePacked else { continue }
            
            // success!
            try done()
            let commandParameterLength = HCIGeneralEvent.CommandCompleteParameter.length
            let dataLength = min(eventData.count - commandParameterLength, eventParameterLength)
            return Array(eventData[commandParameterLength ..< dataLength])
            
        case HCIGeneralEvent.RemoteNameRequestComplete.rawValue:
            
            guard eventHeader.event == event else { break }
            
            guard let parameter = HCIGeneralEvent.RemoteNameRequestCompleteParameter(byteValue: eventData)
                else { throw AdapterError.GarbageResponse(Data(byteValue: eventBuffer)) }
            
            if commandParameterData.isEmpty == false {
                
                guard let commandParameter = LinkControlCommand.RemoteNameRequestParameter(byteValue: commandParameterData)
                    else { fatalError("HCI Command 'RemoteNameRequest' was sent, but the event parameter data does not correspond to 'RemoteNameRequestParameter'") }
                
                // must be different, for some reason
                guard commandParameter.address != parameter.address else { continue }
            }
            
            // success!
            try done()
            let dataLength = min(eventData.count - 1, eventParameterLength)
            return Array(eventData.suffix(dataLength))
            
        // all other events
        default:
            
            guard eventHeader.event == event else { break }
            
            try done()
            let dataLength = min(eventData.count, eventParameterLength)
            return Array(eventData.suffix(dataLength))
        }
    }
    
    // throw timeout error
    throw POSIXError(rawValue: ETIMEDOUT)!
}

// MARK: - Internal Constants

let SOL_HCI: CInt = 0


