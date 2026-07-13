package io.tutio.app.core.designsystem

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.compositionLocalOf

/**
 * Design System do Tut.Io. Material 3 é usado só como infraestrutura (Theme/Typography/
 * Shapes) — a aparência final segue os tokens do web (docs/UI_TOKENS.md), nunca cores/
 * estilos soltos nas telas (regra do CLAUDE.md "Paridade visual").
 */
private val LocalTutIoColors = compositionLocalOf { TutIoLightColors }
private val LocalTutIoSpacing = compositionLocalOf { TutIoSpacing }
private val LocalTutIoRadius = compositionLocalOf { TutIoRadius }

object TutIoTheme {
    val colors: TutIoColorTokens
        @Composable @ReadOnlyComposable get() = LocalTutIoColors.current

    val spacing: TutIoSpacingTokens
        @Composable @ReadOnlyComposable get() = LocalTutIoSpacing.current

    val radius: TutIoRadiusTokens
        @Composable @ReadOnlyComposable get() = LocalTutIoRadius.current

    val gradients: TutIoGradients
        get() = TutIoGradients
}

private fun ColorScheme.applyTutIoColors(tokens: TutIoColorTokens): ColorScheme = copy(
    primary = tokens.primary,
    onPrimary = tokens.primaryForeground,
    secondary = tokens.secondary,
    onSecondary = tokens.secondaryForeground,
    tertiary = tokens.accent,
    onTertiary = tokens.accentForeground,
    background = tokens.background,
    onBackground = tokens.foreground,
    surface = tokens.card,
    onSurface = tokens.cardForeground,
    surfaceVariant = tokens.muted,
    onSurfaceVariant = tokens.mutedForeground,
    error = tokens.destructive,
    onError = tokens.destructiveForeground,
    outline = tokens.border,
    outlineVariant = tokens.input,
)

// Nome diferente de TutIoShapes (object em TutIoRadius.kt, com as formas por componente:
// button/card/input/chip) para não colidir — este aqui é só o Shapes() do M3 (infra).
private val TutIoMaterialShapes = Shapes(
    extraSmall = androidx.compose.foundation.shape.RoundedCornerShape(TutIoRadius.sm),
    small = androidx.compose.foundation.shape.RoundedCornerShape(TutIoRadius.md),
    medium = androidx.compose.foundation.shape.RoundedCornerShape(TutIoRadius.lg),
    large = androidx.compose.foundation.shape.RoundedCornerShape(TutIoRadius.xl3),
    extraLarge = androidx.compose.foundation.shape.RoundedCornerShape(TutIoRadius.xl4),
)

// Tema claro e o padrao do produto (nunca segue o tema do sistema): profiles.theme_preference
// ja existe no backend para preferencia futura do usuario, mas aplicar essa preferencia ao
// tema renderizado e trabalho futuro (ver docs/ANDROID_PROGRESS.md, Dominio 8) — nao
// escopo desta correcao, que so fixa o padrao claro.
@Composable
fun TutIoTheme(
    darkTheme: Boolean = false,
    content: @Composable () -> Unit,
) {
    val tokens = if (darkTheme) TutIoDarkColors else TutIoLightColors
    val baseScheme: ColorScheme = if (darkTheme) {
        androidx.compose.material3.darkColorScheme()
    } else {
        androidx.compose.material3.lightColorScheme()
    }
    val colorScheme = baseScheme.applyTutIoColors(tokens)

    CompositionLocalProvider(
        LocalTutIoColors provides tokens,
        LocalTutIoSpacing provides TutIoSpacing,
        LocalTutIoRadius provides TutIoRadius,
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = TutIoTypography,
            shapes = TutIoMaterialShapes,
            content = content,
        )
    }
}
