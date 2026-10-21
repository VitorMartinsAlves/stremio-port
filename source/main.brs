sub Main()
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.SetMessagePort(port)
    scene = screen.CreateScene("HomeScene")
    screen.Show()

    while true
        msg = Wait(0, port)
        if Type(msg) = "roSGScreenEvent" then
            if msg.IsScreenClosed() then return
        end if
    end while
end sub
