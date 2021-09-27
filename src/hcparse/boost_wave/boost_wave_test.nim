import ./boost_wave
import hmisc/core/all

echo cwaveDl

proc main() =
  var ctx = newWaveContext(allocCStringArray(["#warning \"123\"\n"])[0], "<Unknown>".cstring)
  ctx.setFoundWarningDirective(
    proc(
      ctx: ptr WaveContextImplHandle,
      message: ptr WaveTokenListHandle
    ): EntryHandling =
      echo "Found warning directive with ",
        tokenListLen(message), " elements, value = ",
        tokenListToStr(message)

      return EntryHandlingSkip
  )

  var first: ptr WaveIteratorHandle = ctx.first()
  while first != ctx.last():
    let tok = first.getTok()
    echo "TOK: [", tok.getValue(), "] KIND: ", tok.kind()
    first.advance()

when isMainModule:
  main()
