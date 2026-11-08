import {useTranslation} from 'react-i18next';
import {FieldError} from '~/components/ui/field';
import errors from '~/languages/en/errors';

type ValidationKey = keyof typeof errors.validation;

const isValidationKey = (message: string): message is ValidationKey =>
  Object.hasOwn(errors.validation, message);

type ConformFieldErrorProps = {
  field: {errorId: string; errors?: string[]};
};

/**
 * Renders a Conform field's errors under its `errorId`, translating each schema
 * message found in `errors.validation` and showing any other message as written.
 */
const ConformFieldError = ({field}: ConformFieldErrorProps) => {
  const {t} = useTranslation('errors', {keyPrefix: 'validation'});

  return (
    <FieldError
      errors={field.errors?.map((message) => ({
        message: isValidationKey(message) ? t(message) : message,
      }))}
      id={field.errorId}
    />
  );
};

export default ConformFieldError;
