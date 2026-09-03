import 'package:patchbay/patchbay_host.dart';
import 'package:test/test.dart';

const PatchbayResponseValueSchema _string = PatchbayResponseValueSchema(
  type: PatchbayResponseType.string,
);

PatchbayResponseSchema _schema() => const PatchbayResponseSchema(
  accepted: PatchbayResponseValueSchema(
    type: PatchbayResponseType.object,
    properties: <String, PatchbayResponseValueSchema>{
      'kind': _string,
      'session': PatchbayResponseValueSchema(
        type: PatchbayResponseType.string,
        nullable: true,
      ),
    },
    required: <String>{'kind', 'session'},
    discriminator: 'kind',
    variants: <String, PatchbayResponseValueSchema>{
      'ready': PatchbayResponseValueSchema(
        type: PatchbayResponseType.object,
        properties: <String, PatchbayResponseValueSchema>{'value': _string},
        required: <String>{'value'},
      ),
      'idle': PatchbayResponseValueSchema(type: PatchbayResponseType.object),
    },
  ),
);

void main() {
  test(
    'round trips required nullable closed variants and unknown-field policy',
    () {
      final PatchbayResponseSchema schema = PatchbayResponseSchema.fromJson(
        _schema().toJson(),
      );

      expect(
        validatePatchbayResponsePayload(schema.accepted, <String, Object?>{
          'kind': 'ready',
          'session': null,
          'value': 'ok',
        }),
        isEmpty,
      );
      expect(
        validatePatchbayResponsePayload(schema.accepted, <String, Object?>{
          'kind': 'other',
          'session': 's',
          'secret': 'must-not-echo',
        }).map((PatchbayResponseValidationIssue issue) => issue.reason),
        containsAll(<String>['unknownVariant', 'unknownField']),
      );
    },
  );

  test('reports only closed reasons and never includes payload values', () {
    final List<PatchbayResponseValidationIssue> issues =
        validatePatchbayResponsePayload(_schema().accepted, <String, Object?>{
          'kind': 'ready',
          'session': 42,
          'password': 'top-secret',
        });

    expect(
      issues.map((PatchbayResponseValidationIssue issue) => issue.reason),
      everyElement(
        isIn(<String>{
          'missingField',
          'unexpectedNull',
          'wrongType',
          'unknownVariant',
          'unknownField',
        }),
      ),
    );
    expect(
      issues.map((issue) => issue.toJson()).toString(),
      isNot(contains('top-secret')),
    );
  });

  test('discriminator wrong type differs from an unknown string variant', () {
    final List<PatchbayResponseValidationIssue> wrongType =
        validatePatchbayResponsePayload(_schema().accepted, <String, Object?>{
          'kind': 7,
          'session': null,
        });
    final List<PatchbayResponseValidationIssue> unknownVariant =
        validatePatchbayResponsePayload(_schema().accepted, <String, Object?>{
          'kind': 'future',
          'session': null,
        });

    expect(wrongType.first.reason, 'wrongType');
    expect(wrongType.first.field, r'$.payload.kind');
    expect(unknownVariant.first.reason, 'unknownVariant');
    expect(unknownVariant.first.field, r'$.payload.kind');
  });

  test('nullable string allowedValues closes execution reason codes', () {
    const PatchbayResponseValueSchema reasonCode = PatchbayResponseValueSchema(
      type: PatchbayResponseType.string,
      nullable: true,
      allowedValues: <String>{'deviceOffline', 'confirmationExpired'},
    );
    final PatchbayResponseValueSchema roundTripped =
        PatchbayResponseValueSchema.fromJson(reasonCode.toJson());

    expect(validatePatchbayResponsePayload(roundTripped, null), isEmpty);
    expect(
      validatePatchbayResponsePayload(roundTripped, 'deviceOffline'),
      isEmpty,
    );
    expect(
      validatePatchbayResponsePayload(roundTripped, 'vendor-secret').single,
      isA<PatchbayResponseValidationIssue>()
          .having((issue) => issue.reason, 'reason', 'unknownVariant')
          .having(
            (issue) => issue.toJson().toString(),
            'redacted issue',
            isNot(contains('vendor-secret')),
          ),
    );
  });

  test(
    'terminal envelope defects fail closed with allowed reasons and paths',
    () {
      const PatchbayResponseValueSchema terminal = PatchbayResponseValueSchema(
        type: PatchbayResponseType.object,
        properties: <String, PatchbayResponseValueSchema>{'value': _string},
        required: <String>{'value'},
      );
      const PatchbayResponseSchema schema = PatchbayResponseSchema(
        accepted: PatchbayResponseValueSchema(
          type: PatchbayResponseType.object,
        ),
        terminal: <String, PatchbayResponseValueSchema>{
          'completed': terminal,
          'failed': terminal,
          'cancelled': terminal,
        },
      );
      final List<({Object? payload, String reason, String field})> cases =
          <({Object? payload, String reason, String field})>[
            (payload: null, reason: 'wrongType', field: r'$.payload'),
            (
              payload: const <String, Object?>{},
              reason: 'missingField',
              field: r'$.payload.events',
            ),
            (
              payload: const <String, Object?>{'events': null},
              reason: 'unexpectedNull',
              field: r'$.payload.events',
            ),
            (
              payload: const <String, Object?>{'events': 'bad'},
              reason: 'wrongType',
              field: r'$.payload.events',
            ),
            (
              payload: const <String, Object?>{'events': <Object?>[]},
              reason: 'missingField',
              field: r'$.payload.events',
            ),
            (
              payload: const <String, Object?>{
                'events': <Object?>[42],
              },
              reason: 'wrongType',
              field: r'$.payload.events[0]',
            ),
            (
              payload: const <String, Object?>{
                'events': <Object?>[<String, Object?>{}],
              },
              reason: 'missingField',
              field: r'$.payload.events[0].phase',
            ),
            (
              payload: const <String, Object?>{
                'events': <Object?>[
                  <String, Object?>{'phase': null},
                ],
              },
              reason: 'unexpectedNull',
              field: r'$.payload.events[0].phase',
            ),
            (
              payload: const <String, Object?>{
                'events': <Object?>[
                  <String, Object?>{'phase': 7},
                ],
              },
              reason: 'wrongType',
              field: r'$.payload.events[0].phase',
            ),
            (
              payload: const <String, Object?>{
                'events': <Object?>[
                  <String, Object?>{'phase': 'running'},
                ],
              },
              reason: 'unknownVariant',
              field: r'$.payload.events[0].phase',
            ),
            (
              payload: const <String, Object?>{
                'events': <Object?>[
                  <String, Object?>{'phase': 'completed'},
                ],
              },
              reason: 'missingField',
              field: r'$.payload.events[0].payload',
            ),
          ];

      for (final testCase in cases) {
        final PatchbayResponseValidationIssue issue =
            validatePatchbayTerminalPayload(schema, testCase.payload).single;
        expect(issue.reason, testCase.reason);
        expect(issue.field, testCase.field);
      }
    },
  );

  test('caps one payload validation at twenty issues', () {
    final PatchbayResponseValueSchema schema = PatchbayResponseValueSchema(
      type: PatchbayResponseType.object,
      properties: <String, PatchbayResponseValueSchema>{
        for (var index = 0; index < 30; index += 1) 'field$index': _string,
      },
      required: <String>{
        for (var index = 0; index < 30; index += 1) 'field$index',
      },
    );

    expect(
      validatePatchbayResponsePayload(schema, const <String, Object?>{}),
      hasLength(patchbayResponseValidationMaxIssues),
    );
  });

  test('registry rejects schemas beyond depth and field limits', () {
    PatchbayResponseValueSchema nested = const PatchbayResponseValueSchema(
      type: PatchbayResponseType.object,
    );
    for (var depth = 0; depth < patchbayResponseSchemaMaxDepth; depth += 1) {
      nested = PatchbayResponseValueSchema(
        type: PatchbayResponseType.object,
        properties: <String, PatchbayResponseValueSchema>{'next': nested},
      );
    }

    expect(
      () => validatePatchbayResponseSchema(
        PatchbayResponseSchema(accepted: nested),
      ),
      throwsArgumentError,
    );
    expect(
      () => validatePatchbayResponseSchema(
        PatchbayResponseSchema(
          accepted: PatchbayResponseValueSchema(
            type: PatchbayResponseType.object,
            properties: <String, PatchbayResponseValueSchema>{
              for (
                var index = 0;
                index <= patchbayResponseSchemaMaxFields;
                index += 1
              )
                'field$index': _string,
            },
          ),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('additionalProperties must be explicit on the wire', () {
    expect(
      () => PatchbayResponseSchema.fromJson(<String, Object?>{
        'accepted': <String, Object?>{
          'type': 'object',
          'properties': const <String, Object?>{},
          'required': const <String>[],
        },
      }),
      throwsFormatException,
    );
  });
}
