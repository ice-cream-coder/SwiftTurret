//------------------------------------------------------------------------------
//
// Turret.swift4a
// Swift For Arduino
//
// Created by Ice Cream on 5/25/25.
// Copyright © 2025 Ice Cream. All rights reserved.
//
//------------------------------------------------------------------------------

import AVR

//------------------------------------------------------------------------------
// Setup / Functions
//------------------------------------------------------------------------------

// Insert code here to setup IO pins, define properties, add functions, etc.

// MARK: - Globals

var micros: UInt32 = 0
var microsPerTimeout: UInt16 = 50
var microsIncrementer: UInt32 = UInt32(microsPerTimeout)

// MARK: - Serial
SetupSerial()
print("started")

// MARK: - Servo
 SetupServos(capacity: 3)
let rollServo = addServo(pin: 12)!
setServoSpeed(rollServo, speedOrAngle: 80)
let pitchServo = addServo(pin: 11)!
setServoSpeed(pitchServo, speedOrAngle: 80)
let yawServo = addServo(pin: 10)!
let yawStop = 85
setServoSpeed(yawServo, speedOrAngle: yawStop)

enum State {
    case stopped
    case waiting
    case yawLeft
    case yawRight
    case pitchUp
    case pitchDown
    case fire
    case unload

    var duration: UInt32 {
        switch self {
            case .stopped:
                return 0
            case .waiting:
                return 0
            case .yawLeft:
                return 100_000
            case .yawRight:
                return 100_000
            case .pitchUp:
                return 100_000
            case .pitchDown:
                return 100_000
            case .fire:
                return 750_000
            case .unload:
                return 750_000 * 6
        }
    }
}
var state = State.stopped
var lastStateChange: UInt32 = 0
var pitchAngle: UInt8 = 80

// MARK: - IR

IRReceiver.default.onReceive { command in
    switch state {
    case .waiting:
        lastStateChange = micros
        switch command {
            case .up:
                state = .pitchUp
                if pitchAngle < 150 {
                    pitchAngle += 5
                    setServoSpeed(pitchServo, speedOrAngle: pitchAngle)
                }
            case .down:
                state = .pitchDown
                if pitchAngle > 30 {
                    pitchAngle -= 5
                    setServoSpeed(pitchServo, speedOrAngle: pitchAngle)
                }
            case .left:
                state = .yawLeft
                setServoSpeed(yawServo, speedOrAngle: 30)
            case .right:
                state = .yawRight
                setServoSpeed(yawServo, speedOrAngle: 150)
            case .ok:
                state = .fire
                setServoSpeed(rollServo, speedOrAngle: 150)
            case ._1:
                print("_1")
            case ._2:
                print("_2")
            case ._3:
                print("_3")
            case ._4:
                print("_4")
            case ._5:
                print("_5")
            case ._6:
                print("_6")
            case ._7:
                print("_7")
            case ._8:
                print("_8")
            case ._9:
                print("_9")
            case ._0:
                print("_0")
            case .star:
                state = .unload
                setServoSpeed(rollServo, speedOrAngle: 150)
            case .pound:
                print("pound")
            case .unknown:
                print("unknown")
        }
    case .yawLeft:
        if command == .left {
            lastStateChange = micros
        }
    case .yawRight:
        if command == .right {
            lastStateChange = micros
        }
    case .pitchUp:
        if command == .up {
            lastStateChange = micros
            if pitchAngle < 150 {
                pitchAngle += 5
                setServoSpeed(pitchServo, speedOrAngle: pitchAngle)
            }
        }
    case .pitchDown:
        if command == .down {
            lastStateChange = micros
            if pitchAngle > 30 {
                pitchAngle -= 5
                setServoSpeed(pitchServo, speedOrAngle: pitchAngle)
            }
        }
    default:
        break
    }
}

//------------------------------------------------------------------------------
// Main Loop
//------------------------------------------------------------------------------

setupTimeout(afterMicroseconds: microsPerTimeout)

while mainLoopRunning {
    if didTimeout() {
        micros += microsIncrementer
        resetTimeoutFlag()
        IRReceiver.default.update()
        updateServos()
        if state != .waiting {
            let stateDuration = state.duration
            if micros - lastStateChange > stateDuration {
                switch state {
                case .yawLeft, .yawRight:
                    setServoSpeed(yawServo, speedOrAngle: yawStop)
                case .fire, .unload:
                    setServoSpeed(rollServo, speedOrAngle: 80)
                default:
                    break
                }
                state = .waiting
            }
        }
    }
}

//------------------------------------------------------------------------------
