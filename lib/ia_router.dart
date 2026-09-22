/// Provider-blind LLM / TTS client.
///
/// Host apps call [IaRouter.configure] with an API key, then use
/// [IaRouter.llm] / [IaRouter.tts]. Vendor details stay inside the package.
library;

export 'src/contract/chat_models.dart';
export 'src/contract/exceptions.dart';
export 'src/contract/llm_client.dart';
export 'src/contract/tts_client.dart';
export 'src/contract/tts_models.dart';
export 'src/ia_router_facade.dart';
