package com.aaazero.yueh

import com.onesignal.notifications.INotificationServiceExtension
import com.onesignal.notifications.INotificationReceivedEvent

/** Group even when the Flutter engine is not alive to receive the push. */
@androidx.annotation.Keep
class ShellNotificationExtension : INotificationServiceExtension {
    override fun onNotificationReceived(event: INotificationReceivedEvent) {
        // §2.3: once switched to A, IM pushes must not show even before Dart logs out.
        if (ShellApplication.instance.getSharedPreferences("im_shell", android.content.Context.MODE_PRIVATE)
            .getBoolean("push.disabled", false)) {
            event.preventDefault()
            return
        }
        val data = event.notification.additionalData ?: return
        val thread = data.optString("thread_id").ifEmpty {
            data.optString("chat_id").ifEmpty { data.optString("chatId") }
        }
        if (thread.isNotEmpty()) event.notification.setExtender { builder -> builder.setGroup(thread) }
    }
}
