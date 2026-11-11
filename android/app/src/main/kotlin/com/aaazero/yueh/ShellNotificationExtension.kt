package com.aaazero.yueh

import com.onesignal.notifications.INotificationServiceExtension
import com.onesignal.notifications.INotificationReceivedEvent

/** Group even when the Flutter engine is not alive to receive the push. */
@androidx.annotation.Keep
class ShellNotificationExtension : INotificationServiceExtension {
    override fun onNotificationReceived(event: INotificationReceivedEvent) {
        val data = event.notification.additionalData ?: return
        val thread = data.optString("thread_id").ifEmpty {
            data.optString("chat_id").ifEmpty { data.optString("chatId") }
        }
        if (thread.isNotEmpty()) event.notification.setExtender { builder -> builder.setGroup(thread) }
    }
}
