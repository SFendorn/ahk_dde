class DDE_Conversation {
  __New(DDE_Server, DDE_Topic := "")
  {
    ; count the number of connections made in this session
    ; the index is appended to the client gui to avoid name clashes for multiple connections per session
    static nConnectionIndex := 0

    this.Server := DDE_Server
    this.Topic := DDE_Topic == "" ? DDE_Server : DDE_Topic

    ; commented out IDs are here for reference, but currently unused
    ;this.CF_TEXT := 1
    this.WM_DDE_INITIATE  := 0x3E0
    this.WM_DDE_TERMINATE := 0x3E1
    ;this.WM_DDE_ADVISE   := 0x3E2
    ;this.WM_DDE_UNADVISE := 0x3E3
    this.WM_DDE_ACK       := 0x3E4
    ;this.WM_DDE_DATA     := 0x3E5
    ;this.WM_DDE_REQUEST  := 0x3E6
    ;this.WM_DDE_POKE     := 0x3E7
    this.WM_DDE_EXECUTE   := 0x3E8

    ; the ui is created to act as a client window for the DDE communication
    this.guiClient := Gui("+LastFound", "DDEConnection" nConnectionIndex++ " " DDE_Server ":" DDE_Topic)
    this.guiClient.Show("hide w1 h1")
    this.ClientHwnd := WinExist()
    this.ServerHwnd := 0
    this.connected := false

    ; the callback here is created so that each instance can have its own acknowledge function
    ; this avoids races when using more than one connection per session
    this.DDE_Ack_wParam := 0
    this.DDE_Ack_Hwnd := 0
    this.OnAck := OnDDEAck.Bind(&this)
    OnMessage(this.WM_DDE_ACK, this.OnAck)
  }

  IsConnected => this.connected

  Connect(timeout := 60000)
  {
    nAtom_Server := DllCall("GlobalAddAtom", "str", this.Server, "Ushort")
    nAtom_Topic := DllCall("GlobalAddAtom", "str", this.Topic, "Ushort")
    DllCall("SendMessage", "UInt", 0xFFFF, "UInt", this.WM_DDE_INITIATE, "UInt", this.ClientHwnd, "UInt", nAtom_Server | nAtom_Topic << 16)
    this.ServerHwnd := this.WaitForAck(timeout)
    DllCall("DeleteAtom", "Ushort", nAtom_Server)
    DllCall("DeleteAtom", "Ushort", nAtom_Topic)

    if (!this.ServerHwnd)
    {
      ; common error: if target app is not running or declines the DDE connection
      throw Error("DDE Initialization failed", A_ThisFunc, "No response from server '" this.Server ":" this.Topic "'")
    }

    if (!this.ClientHwnd)
    {
      ; unlikely error: Would mean that the ui has not been successfully created or its hwnd is not correctly detected
      throw Error("DDE Initialization failed", A_ThisFunc, "AHK Client has not been initialized")
    }
    this.connected := true
  }

  Execute(command, timeout := 60000)
  {
    if (!this.connected)
    {
      throw Error("DDE Execution failed", A_ThisFunc, "There is no active DDE connection to execute on")
    }

    ; length +1 for terminating zero
    ; length times two because of Unicode (UTF-16)
    len := (StrLen(command)+1)*2
    hCmd := DllCall("GlobalAlloc", "Uint", 0x0002, "Uint", len)
    pCmd := DllCall("GlobalLock" , "Uint", hCmd)
    DllCall("lstrcpyW", "Uint", pCmd, "str", command)
    DllCall("GlobalUnlock", "Uint", hCmd)

    DllCall("PostMessage", "UInt", this.ServerHwnd, "UInt", this.WM_DDE_EXECUTE , "UInt", this.ClientHwnd, "UInt", hCmd)

    return this.WaitForAck(timeout)
  }

  Disconnect()
  {
    this.guiClient.Destroy()
    DllCall("PostMessage", "UInt", this.ServerHwnd, "UInt", this.WM_DDE_TERMINATE , "UInt", this.ClientHwnd, "Int", 0)
    this.connected := false
  }

  WaitForAck(timeout := 60000)
  {
    end_time := A_TickCount + timeout
    while (A_TickCount < end_time)
    {
      if (this.ClientHwnd = this.DDE_Ack_Hwnd)
      {
        this.DDE_Ack_Hwnd := 0
        return this.DDE_Ack_wParam
      }
      sleep 500
    }
    return 0
  }
}

OnDDEAck(&obj, wParam, LParam, MsgID, hWnd)
{
  Critical
  obj.DDE_Ack_wParam := wParam
  obj.DDE_Ack_Hwnd := hWnd
}
