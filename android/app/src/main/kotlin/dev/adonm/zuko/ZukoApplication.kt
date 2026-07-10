package dev.adonm.zuko

import android.app.Application
import computer.iroh.IrohAndroid

class ZukoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Iroh's resolver needs Android LinkProperties. The call is idempotent
        // and must happen before constructing an Endpoint.
        IrohAndroid.installAndroidContext(applicationContext)
    }
}
