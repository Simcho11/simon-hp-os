import Quickshell
import Quickshell.Services.Pam
import Quickshell.Io
import QtQuick
ShellRoot {
  PamContext {
    id: pam
    config: "login"
    user: Quickshell.env("USER")
    Component.onCompleted: start()
    onPamMessage: {
      if (responseRequired && !responseVisible && message.trim() === "Password:") {
        console.log("PAM_PASSWORD_CONVERSATION_REACHED");
        child.running = true;
      }
    }
    onCompleted: result => { console.log("PAM_COMPLETED", result); Qt.quit(); }
    onError: error => { console.log("PAM_ERROR", error); Qt.quit(); }
  }
  Process {
    id: child
    command: ["/usr/bin/python3", "-c", "import os; assert 'native-pam' not in os.environ.get('LD_PRELOAD', '') + os.environ.get('LD_LIBRARY_PATH', ''); print('CHILD_LOADER_ENV_UNCHANGED'); maps=open('/proc/%s/maps' % os.getppid()).read(); pam=[line for line in maps.splitlines() if '/libpam.so.' in line]; assert pam and all('/usr/lib/aarch64-linux-gnu/' in line for line in pam), pam; print('PAM_HOST_LIBRARY_MAPPED')"]
    stdout: StdioCollector { onStreamFinished: console.log(this.text.trim()) }
    onExited: (code, status) => { console.log("CHILD_EXIT", code); pam.abort(); Qt.quit(); }
  }
  Timer { interval: 5000; running: true; onTriggered: Qt.quit() }
}
