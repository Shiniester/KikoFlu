package com.meteor.kikoeruflutter

internal fun restoredVideoPortrait(
    naturalPortrait: Boolean,
    autoRotate: Boolean,
    userRotation: Int,
    deviceOrientation: Int?,
    entryPortrait: Boolean?
): Boolean? {
    val rotation = if (autoRotate) {
        if (deviceOrientation == null || deviceOrientation < 0) return entryPortrait
        ((deviceOrientation + 45) / 90) % 4
    } else userRotation
    val rotated = rotation == 1 || rotation == 3
    return naturalPortrait != rotated
}
