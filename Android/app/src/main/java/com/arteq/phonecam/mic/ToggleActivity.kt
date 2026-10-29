package com.arteq.phonecam.mic

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Turns the mic on or off for the Quick Settings tile. Android only lets an app start using the
 * microphone while one of its screens is showing, so this invisible one does it and closes.
 */
class ToggleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when {
            MicService.instance != null -> MicService.stop(this)
            !MainActivity.hasPermissions(this) -> startActivity(Intent(this, MainActivity::class.java))
            else -> MicService.start(this)
        }
        finish()
    }
}
