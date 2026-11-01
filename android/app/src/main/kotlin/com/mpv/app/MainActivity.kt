package com.mpv.app

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    companion object {
        init {
            // librust_lib_pr_app.so referencia símbolos de libc++
            // (p.ej. _ZTISt12length_error) sin declararla en DT_NEEDED:
            // si no está cargada antes, dlopen falla con
            // "cannot locate symbol _ZTISt12length_error".
            try {
                System.loadLibrary("c++_shared")
            } catch (e: Throwable) {
                android.util.Log.e("MainActivity", "c++_shared: $e")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Dibujar también en la zona del notch/punch-hole (evita franja negra)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
    }
}
