import type {ReactElement, ReactNode} from 'react';
import {Fragment} from 'react';
import ConformFieldError from '~/components/form/conform-field-error';
import {
  Field,
  FieldContent,
  FieldDescription,
  FieldLabel,
} from '~/components/ui/field';

type ConformFieldProps = {
  children: (controlOptions: {ariaDescribedBy?: string}) => ReactElement;
  description?: ReactNode;
  field: {
    descriptionId: string;
    errorId: string;
    errors?: string[];
    id: string;
    key?: string;
  };
  label: ReactNode;
  orientation?: 'horizontal' | 'vertical';
};

/**
 * Wires one Conform field to its label, description and errors. The caller
 * renders the control, spreading the Conform props for that control with the
 * `controlOptions` the child receives. A group of controls stays composed.
 */
const ConformField = ({
  children,
  description,
  field,
  label,
  orientation = 'vertical',
}: ConformFieldProps) => {
  // Conform's prop getters leave `key` out, and its list intents reach an
  // uncontrolled control only by remounting it when `field.key` changes.
  const control = (
    <Fragment key={field.key}>
      {children({
        ariaDescribedBy: description ? field.descriptionId : undefined,
      })}
    </Fragment>
  );
  const fieldLabel = <FieldLabel htmlFor={field.id}>{label}</FieldLabel>;
  const details = (
    <>
      {description ?
        <FieldDescription id={field.descriptionId}>
          {description}
        </FieldDescription>
      : undefined}
      <ConformFieldError field={field} />
    </>
  );

  return (
    <Field
      data-invalid={field.errors ? true : undefined}
      orientation={orientation}
    >
      {orientation === 'horizontal' ?
        <>
          {control}
          <FieldContent>
            {fieldLabel}
            {details}
          </FieldContent>
        </>
      : <>
          {fieldLabel}
          {control}
          {details}
        </>
      }
    </Field>
  );
};

export default ConformField;
