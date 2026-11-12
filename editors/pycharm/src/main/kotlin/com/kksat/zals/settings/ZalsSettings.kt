package com.kksat.zals.settings

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.util.xmlb.XmlSerializerUtil

@State(
    name = "com.kksat.zals.settings.ZalsSettings",
    storages = [Storage("ZalsSettings.xml")]
)
class ZalsSettings : PersistentStateComponent<ZalsSettings> {
    var executablePath: String = ""
    var validationEnabled: Boolean = true
    var lintEnabled: Boolean = true
    var lintPath: String = "ansible-lint"

    override fun getState(): ZalsSettings = this

    override fun loadState(state: ZalsSettings) {
        XmlSerializerUtil.copyBean(state, this)
    }

    companion object {
        val instance: ZalsSettings
            get() = ApplicationManager.getApplication().getService(ZalsSettings::class.java)
    }
}
