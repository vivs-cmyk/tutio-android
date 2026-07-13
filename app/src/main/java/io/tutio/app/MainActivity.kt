package io.tutio.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.view.WindowCompat
import io.tutio.app.core.designsystem.TutIoTheme
import io.tutio.app.core.navigation.TutIoNavHost

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Tema claro é o padrão do produto (TutIoTheme): status bar e navigation bar usam
        // ícones escuros sobre fundo claro, não o comportamento padrão do sistema.
        WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = true
        WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightNavigationBars = true

        val sessionRepository = (application as TutIoApplication).sessionRepository

        setContent {
            TutIoTheme {
                TutIoNavHost(sessionRepository = sessionRepository)
            }
        }
    }
}
