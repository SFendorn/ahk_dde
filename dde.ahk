class DDE_Conversation {
  __New(DDE_Server, DDE_Topic := "")
  {
    ; count the number of connections made in this session
    ; the index is appended to the client gui to avoid name clashes for multiple connections per session
    static nConnectionIndex := 0

    this.Server := DDE_Server
    this.Topic := DDE_Topic == "" ? DDE_Server : DDE_Topic

    ; commented out IDs are here for reference, but currently unused
    this.CF_TEXT          := 1
    this.CF_UNICODETEXT   := 13
    this.WM_DDE_INITIATE  := 0x3E0
    this.WM_DDE_TERMINATE := 0x3E1
    ;this.WM_DDE_ADVISE   := 0x3E2
    ;this.WM_DDE_UNADVISE := 0x3E3
    this.WM_DDE_ACK       := 0x3E4
    this.WM_DDE_DATA      := 0x3E5
    this.WM_DDE_REQUEST   := 0x3E6
    ;this.WM_DDE_POKE     := 0x3E7
    this.WM_DDE_EXECUTE   := 0x3E8

    ; the ui is created to act as a client window for the DDE communication
    this.guiClient := Gui("+LastFound", "DDEConnection" nConnectionIndex++ " " DDE_Server ":" DDE_Topic)
    this.guiClient.Show("hide w1 h1")
    this.ClientHwnd := WinExist()
    this.ServerHwnds := Array()
    this.SelectedServer := 0
    this.connected := false
  }

  __Delete()
  {
    this.Dispose()
  }

  IsConnected => this.connected

  Connections => this.ServerHwnds

  SelectActiveConnection(index)
  {
    this.SelectedServer := index
  }

  GetActiveConnection()
  {
    return this.ServerHwnds[this.SelectedServer]
  }

  Connect(timeout := 60000)
  {
    ; the callback here is created so that each instance can have its own acknowledge function
    ; this avoids races when using more than one conversation per script
    this.DDE_Ack_Hwnd := 0
    OnAck := OnDDEAck_Init.Bind(&this)
    OnMessage(this.WM_DDE_ACK, OnAck)

    nAtom_Server := DllCall("GlobalAddAtom", "str", this.Server, "Ushort")
    nAtom_Topic := DllCall("GlobalAddAtom", "str", this.Topic, "Ushort")
    DllCall("SendMessage", "UInt", 0xFFFF, "UInt", this.WM_DDE_INITIATE, "UInt", this.ClientHwnd, "UInt", nAtom_Server | nAtom_Topic << 16)
    this.WaitForAck(timeout)
    DllCall("DeleteAtom", "Ushort", nAtom_Server)
    DllCall("DeleteAtom", "Ushort", nAtom_Topic)

    OnMessage(this.WM_DDE_ACK, OnAck, 0)

    if (!this.ServerHwnds.Length)
    {
      ; common error: if target app is not running or declines the DDE connection
      throw Error("DDE Initialization failed", A_ThisFunc, "No response from server '" this.Server ":" this.Topic "'")
    }

    if (!this.ClientHwnd)
    {
      ; unlikely error: Would mean that the ui has not been successfully created, its hwnd is not correctly detected or the object has been disposed of
      throw Error("DDE Initialization failed", A_ThisFunc, "AHK Client has not been initialized")
    }
    this.SelectedServer := 1 ; auto select first found connection
    this.connected := true
    return this.ServerHwnds[this.SelectedServer]
  }

  Execute(command, timeout := 60000)
  {
    if (!this.connected)
    {
      throw Error("DDE Execution failed", A_ThisFunc, "There is no active DDE connection to execute on")
    }

    if (!this.SelectedServer)
    {
      throw Error("DDE Execution failed", A_ThisFunc, "No server selected")
    }

    ; the callback here is created so that each instance can have its own acknowledge function
    ; this avoids races when using more than one conversation per script
    this.DDE_Ack_Hwnd := 0
    OnAck := OnDDEAck_Exec.Bind(&this)
    OnMessage(this.WM_DDE_ACK, OnAck)

    ; length +1 for terminating zero
    ; length times two because of Unicode (UTF-16)
    len := (StrLen(command)+1)*2
    hCmd := DllCall("GlobalAlloc", "UInt", 0x0002, "UInt", len)
    pCmd := DllCall("GlobalLock" , "UInt", hCmd)
    DllCall("lstrcpyW", "UInt", pCmd, "str", command)
    DllCall("GlobalUnlock", "UInt", hCmd)

    DllCall("PostMessage", "UInt", this.ServerHwnds[this.SelectedServer], "UInt", this.WM_DDE_EXECUTE , "UInt", this.ClientHwnd, "UInt", hCmd)

    bSuccess := this.WaitForAck(timeout)

    OnMessage(this.WM_DDE_ACK, OnAck, 0)
    return bSuccess
  }

  Request(item, cfFormat := this.CF_UNICODETEXT, x86 := false, timeout := 60000)
  {
    nPtrSize := x86 ? 4 : 8
    nDataType := x86 ? "int" : "int64"
    arData := Array()
    this.DDE_Messages := Array()
    OnData := OnDDEData_Request.Bind(&this)
    OnMessage(this.WM_DDE_DATA, OnData)

    atomItem := DllCall("GlobalAddAtom", "str", item)
    if (atomItem == 0)
    {
      throw Error("DDE Request failed", A_ThisFunc, "Atom creation failed.")
    }
    lParam := DllCall("PackDDElParam", "UInt", this.WM_DDE_REQUEST, "UInt", cfFormat, "UInt", atomItem)
    if (!DllCall("PostMessage", "UInt", this.ServerHwnds[this.SelectedServer], "UInt", this.WM_DDE_REQUEST , "UInt", this.ClientHwnd, "UInt", lParam))
    {
      DllCall("GlobalDeleteAtom", "UInt", atomItem)
      throw Error("DDE Request failed", A_ThisFunc, "Message was not sent successfully.")
    }
    if (!this.WaitForData(timeout))
    {
      throw Error("DDE Request failed", A_ThisFunc, "Timeout while waiting for response.")
    }
    for i, message in this.DDE_Messages
    {
      hData := 0
      DllCall("UnpackDDElParam", "UInt", 0x3E5, "UInt", message.lParam, "UInt*", &hData, "UInt*", &atomItem)
      if (atomItem == 0)
      {
        continue
      }
      lpDDEData := DllCall("GlobalLock", "Ptr", hData)
      fRelease := NumGet(lpDDEData, 2*nPtrSize, nDataType)
      fAckreq := NumGet(lpDDEData, 4*nPtrSize, nDataType)
      if (cfFormat == NumGet(lpDDEData, 6*nPtrSize, nDataType))
      {
        if (cfFormat == this.CF_UNICODETEXT)
          sResponse := StrGet(lpDDEData + 7*nPtrSize)
        else if (cfFormat == this.CF_TEXT)
          sResponse := StrGet(lpDDEData + 7*nPtrSize, "CP0")
        arData.Push(sResponse)
      }
      if (fAckreq)
      {
        lParamAck := DllCall("PackDDElParam", "UInt", this.WM_DDE_ACK, "UInt", 0x8000, "UInt", atomItem)
        DllCall("PostMessage", "UInt", this.ServerHwnds[this.SelectedServer], "UInt", this.WM_DDE_ACK , "UInt", this.ClientHwnd, "UInt", lParamAck)
      }
      DllCall("GlobalUnlock", "Ptr", hData)
      if (fRelease)
      {
        DllCall("GlobalFree", "Ptr", hData)
      }
    }
    DllCall("GlobalDeleteAtom", "UInt", atomItem)
    return arData
  }

  Disconnect()
  {
    for i, connection in this.ServerHwnds
    {
      DllCall("SendMessage", "UInt", connection, "UInt", this.WM_DDE_TERMINATE , "UInt", this.ClientHwnd, "Int", 0)
    }
    this.ServerHwnds := Array()
    this.connected := false
  }

  Dispose()
  {
    this.guiClient.Destroy()
    this.ClientHwnd := 0
  }

  WaitForAck(timeout := 60000)
  {
    end_time := A_TickCount + timeout
    while (A_TickCount < end_time)
    {
      sleep 500
      if (this.ClientHwnd = this.DDE_Ack_Hwnd)
      {
        this.DDE_Ack_Hwnd := 0
        return true
      }
    }
    return false
  }

  WaitForData(timeout := 60000)
  {
    end_time := A_TickCount + timeout
    while (A_TickCount < end_time)
    {
      sleep 500
      if (0 < this.DDE_Messages.Length && this.ClientHwnd = this.DDE_Messages[1].hWnd)
      {
        return true
      }
    }
    return false
  }
}

OnDDEAck_Init(&obj, wParam, lParam, MsgID, hWnd)
{
  Critical
  obj.ServerHwnds.Push(wParam)
  obj.DDE_Ack_Hwnd := hWnd
}

OnDDEAck_Exec(&obj, wParam, lParam, MsgID, hWnd)
{
  Critical
  obj.DDE_Ack_Hwnd := hWnd
}

OnDDEData_Request(&obj, wParam, lParam, MsgID, hWnd)
{
  Critical
  obj.DDE_Messages.Push(DDE_Message(wParam, lParam, MsgID, hWnd))
}

class DDE_Message {
  __New(wParam, lParam, MsgID, hWnd)
  {
    this.wParam := wParam
    this.lParam := lParam
    this.MsgID := MsgID
    this.hWnd := hWnd
  }
}
