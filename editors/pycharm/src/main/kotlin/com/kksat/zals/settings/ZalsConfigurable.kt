package com.kksat.zals.settings

import com.intellij.openapi.options.Configurable
import com.intellij.ui.components.JBCheckBox
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.FormBuilder
import javax.swing.JComponent
import javax.swing.JPanel

class ZalsConfigurable : Configurable {
    private var mainPanel: JPanel? = null
    private val executablePathField = JBTextField()
    private val validationCheckBox = JBCheckBox("Enable Ansible validation and diagnostics")
    private val lintCheckBox = JBCheckBox("Enable ansible-lint diagnostics")
    private val lintPathField = JBTextField()

    override fun getDisplayName(): String = "Ansible (zals)"

    override fun createComponent(): JComponent {
        mainPanel = FormBuilder.createFormBuilder()
            .addLabeledComponent("zals executable path (leave empty for PATH lookup):", executablePathField, 1, false)
            .addComponent(validationCheckBox, 1)
            .addComponent(lintCheckBox, 1)
            .addLabeledComponent("ansible-lint executable path:", lintPathField, 1, false)
            .addComponentFillVertically(JPanel(), 0)
            .panel

        return mainPanel!!
    }

    override fun isModified(): Boolean {
        val settings = ZalsSettings.instance
        return executablePathField.text != settings.executablePath ||
                validationCheckBox.isSelected != settings.validationEnabled ||
                lintCheckBox.isSelected != settings.lintEnabled ||
                lintPathField.text != settings.lintPath
    }

    override fun apply() {
        val settings = ZalsSettings.instance
        settings.executablePath = executablePathField.text.trim()
        settings.validationEnabled = validationCheckBox.isSelected
        settings.lintEnabled = lintCheckBox.isSelected
        settings.lintPath = lintPathField.text.trim()
    }

    override fun reset() {
        val settings = ZalsSettings.instance
        executablePathField.text = settings.executablePath
        validationCheckBox.isSelected = settings.validationEnabled
        lintCheckBox.isSelected = settings.lintEnabled
        lintPathField.text = settings.lintPath
    }

    override fun disposeUIResources() {
        mainPanel = null
    }
}
