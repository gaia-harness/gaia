/* eslint-disable i18next/no-literal-string -- plain English copy in a fixture */
type SignupFormProps = {
  heading: string;
  onSubmit?: (email: string) => void;
};

const SignupForm = ({heading, onSubmit}: SignupFormProps) => (
  <form
    className="p-4"
    onSubmit={(event) => {
      event.preventDefault();
      const data = new FormData(event.currentTarget);

      onSubmit?.(String(data.get('email')));
    }}
  >
    <h2>{heading}</h2>
    <label htmlFor="signup-email">
      Email
      <input id="signup-email" name="email" type="email" />
    </label>
    <button type="submit">Sign up</button>
  </form>
);

export default SignupForm;
