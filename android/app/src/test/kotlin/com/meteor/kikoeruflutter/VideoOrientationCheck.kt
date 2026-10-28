package com.meteor.kikoeruflutter

fun main() {
    for (naturalPortrait in listOf(true, false)) {
        for (rotation in 0..3) {
            val portrait = naturalPortrait != (rotation % 2 == 1)
            check(restoredVideoPortrait(naturalPortrait, false, rotation, 90, null) == portrait)
            check(restoredVideoPortrait(naturalPortrait, true, 0, rotation * 90, null) == portrait) {
                "Auto rotation must wait for the device direction, not accept the old window"
            }
        }
    }
    check(restoredVideoPortrait(true, true, 1, 359, null) == true)
    check(restoredVideoPortrait(true, true, 0, -1, false) == false)
    check(restoredVideoPortrait(true, true, 0, null, true) == true)
    check(restoredVideoPortrait(true, true, 0, -1, null) == null)
    println("Video orientation checks passed")
}
