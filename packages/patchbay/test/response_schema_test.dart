import 'package:patchbay/patchbay.dart';
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
