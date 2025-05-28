// Author: Mark Oxley
// Date: 26/11/2020
// IDE Version: 4.2
// Description: This library uses Timer1 based interrupt callback functions to
// control a number of servos, giving angles between 0 and 180 degrees.
// If more a servo is added when the capacity has been reached, addServo will return nil.
// Any angle set outside of the range of the servo will be clipped.
// To use:
//    Setup the servo controller
//    Add servos with initial angle and maximum range and offset if required
//    Set the angle to your servos


import AVR

/* Snippets:
 {
        "ServoController":[

            {"partName":"Start servo controller. The capacity denotes the number of servers to be controlled",
                "partCode":"SetupServos(capacity:3)"
            },
            { "partName": "Add a servo to the controller",
                "partCode": "let id = addServo(pin:D5, angle:90)"
            },
            {"partName":"Add a servo to the controller with a 90 degree arc",
                "partCode":"let id = addServo(pin:D5, angle:90, max:90)"
            },
            {"partName":"Add a servo to the controller with a 90 degree arc and an offset of 45 degrees",
                "partCode":"let id = addServo(pin:D5, angle:90, max:90, offset:45)"
            },
            {"partName":"Set the angle of a servo, based on the index returned by addServo",
                "partCode":"let id = addServo(pin:D6, angle:45)\nsetServoAngle(id, angle:60)"}
        ]
 }
 */

private struct Servo {
    var pin:UInt8 = 0
    var time:UInt16 = 0
    var state:Bool = LOW
    var lastUpdate:UInt32 = 0
}

private var servos = [Servo]()
public private(set) var servoCount:UInt8 = 0

func SetupServos(capacity:UInt8) {
    var capacity = Int(capacity)
    servos = [Servo](repeating: Servo(), count: &capacity)
}

func addServo(pin:UInt8) -> UInt8? {
    if servoCount >= servos.count {
        return nil
    }
    servos[Int(servoCount)].pin = pin
    servos[Int(servoCount)].time = 0
    pinMode(pin: pin, mode: OUTPUT)
    defer { servoCount += 1 }
    return servoCount
}

func setServoSpeed(_ index: UInt8, speedOrAngle: UInt8) {
    // Ensure index is valid
    guard index < servoCount else {
        // Or handle error appropriately, e.g., print a message
        return
    }

    // Map speed (0-180) to pulse width (e.g., 1000µs - 2000µs)
    // 0 -> 1000µs (full reverse)
    // 90 -> 1500µs (stop)
    // 180 -> 2000µs (full forward)
    // Formula: Pulse = 1500 + (speed - 90) * (500 / 90)

    let pulseTimeFloat = 1500.0 + (Float(speedOrAngle) - 90.0) * (500.0 / 90.0)

    // Clamp pulse width to a safe/typical range (e.g., 1000µs to 2000µs)
    let clampedPulseTime = max(1000.0, min(2000.0, pulseTimeFloat))

    servos[Int(index)].time = UInt16(safe: clampedPulseTime) ?? 1500
}

func updateServos() {
    for i in 0 ..< Int(servoCount) {
        let servo = servos[i]
        let duration = micros - servo.lastUpdate

        switch servo.state {
        case HIGH where duration > servo.time: // duration (UInt32) compared with servo.time (UInt16, promoted)
            digitalWrite(pin: servo.pin, value: LOW)
            servos[i].state = LOW
            servos[i].lastUpdate = micros
        case LOW where duration > 20_000 - servo.time: // duration (UInt32) compared with lowPulseDurationTarget (UInt16, promoted)
            digitalWrite(pin: servo.pin, value: HIGH)
            servos[i].state = HIGH
            servos[i].lastUpdate = micros
        default:
            break
        }
    }
}
