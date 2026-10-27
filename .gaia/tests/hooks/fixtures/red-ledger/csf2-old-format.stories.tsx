// An old-format (CSF2) story file: the story extractor refuses it with exit 8
// and names the migration command. It sits outside frontend/app/, so
// Storybook never loads it.
const Marker = ({text}: {text: string}) => <p>{text}</p>;

export default {component: Marker, title: 'Internal/CSF2 Old Format'};

const Template = (args: {text: string}) => <Marker {...args} />;

export const Bound = Template.bind({});
