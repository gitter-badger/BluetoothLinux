//
//  Error.swift
//  BlueZ
//
//  Created by Alsey Coleman Miller on 1/12/16.
//  Copyright © 2016 PureSwift. All rights reserved.
//

#if os(Linux)
    import Glibc
#elseif os(OSX) || os(iOS)
    import Darwin.C
#endif

@noreturn func Error(text: String) {
    
    print(text)
    exit(1)
}